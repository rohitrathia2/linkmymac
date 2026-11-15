package com.linkmymac.android.service

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import org.json.JSONObject
import java.security.MessageDigest

/**
 * =============================================================================
 * ClipboardSyncHelper: Bidirectional Cross-Platform Clipboard Synchronizer
 * =============================================================================
 * WHAT IT DOES: Monitors the Android primary system clipboard for changes,
 *               broadcasts copied text strings to connected macOS clients, and
 *               receives remote clipboard updates from macOS to apply locally.
 * HOW IT DOES IT:
 *   1. Registers an `OnPrimaryClipChangedListener` with the Android `ClipboardManager`.
 *   2. On local copy, extracts plain text, computes a SHA-256 fingerprint, and
 *      broadcasts a `CLIPBOARD_EVENT` JSON control frame via `P2PDaemonService`.
 *   3. On remote update, verifies the incoming SHA-256 hash does not match the
 *      last synced value, and writes the text into the Android system clipboard.
 * WHY IT DOES IT: Enables seamless universal copy-paste between Android and Mac
 *                 while strictly eliminating infinite echo ping-pong loops via
 *                 SHA-256 digest deduplication.
 * ANDROID 10+: only the focused app may read the clipboard, so the listener misses
 *              copies made in other apps; MainActivity sends those through
 *              [pushClipboardOnFocus] when LinkMyMac comes to the front.
 * =============================================================================
 */
class ClipboardSyncHelper(context: Context) {

    private val clipboardManager =
        context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager

    /** In-memory clipboard history of recent cross-synced clips */
    val clipboardHistory = java.util.concurrent.CopyOnWriteArrayList<String>()

    /** Observable listener for UI updates */
    @Volatile
    var onClipUpdated: ((String) -> Unit)? = null

    /** Tracks the SHA-256 digest of the last synced content to suppress echo loops */
    @Volatile
    private var lastSyncedHash: String = ""

    /** ClipDescription timestamp of the last clip this helper read; -1 = none yet. */
    @Volatile
    private var lastSeenClipStamp = -1L

    /**
     * Listener callback invoked by Android OS whenever user copies text on phone.
     */
    private val clipListener = ClipboardManager.OnPrimaryClipChangedListener {
        pushCurrentClipboardToMac()
    }

    /**
     * -------------------------------------------------------------------------
     * startMonitoring: Clipboard Listener Registration
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Begins listening to Android OS primary clipboard modifications.
     * HOW IT DOES IT: Attaches `clipListener` to `clipboardManager`.
     * WHY IT DOES IT: Activated upon daemon service startup so any copied text
     *                 on the phone is instantly synced to Mac.
     * -------------------------------------------------------------------------
     */
    fun startMonitoring() {
        clipboardManager.addPrimaryClipChangedListener(clipListener)
    }

    /**
     * -------------------------------------------------------------------------
     * stopMonitoring: Clipboard Listener Teardown
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Detaches the clipboard modification listener.
     * HOW IT DOES IT: Removes `clipListener` from `clipboardManager`.
     * WHY IT DOES IT: Prevents memory leaks and background processing when the daemon
     *                 service terminates.
     * -------------------------------------------------------------------------
     */
    fun stopMonitoring() {
        clipboardManager.removePrimaryClipChangedListener(clipListener)
    }

    /**
     * -------------------------------------------------------------------------
     * pushCurrentClipboardToMac: Outbound Clipboard Change Dispatcher
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Reads current phone clipboard contents and broadcasts to Mac.
     * HOW IT DOES IT:
     *   1. Queries `primaryClip` item text.
     *   2. Computes SHA-256 digest of the UTF-8 text string.
     *   3. If the digest matches `lastSyncedHash`, aborts immediately (deduplication).
     *   4. Updates `lastSyncedHash` and packages a `CLIPBOARD_EVENT` JSON frame:
     *      `{ type: "CLIPBOARD_EVENT", contentType: "PLAIN_TEXT", textValue, contentSha256 }`.
     *   5. Broadcasts the frame across all active P2P client sessions.
     * WHY IT DOES IT: Delivers sub-100ms clipboard synchronization to the desktop.
     * -------------------------------------------------------------------------
     */
    fun pushCurrentClipboardToMac() {
        val clip = clipboardManager.primaryClip ?: return // null when Android denies a background read
        lastSeenClipStamp = clip.description.timestamp
        if (clip.itemCount == 0) return
        // Password managers flag secrets (ClipDescription.EXTRA_IS_SENSITIVE, a literal since the
        // constant is API 33). Never send those to the Mac.
        if (clip.description.extras?.getBoolean("android.content.extra.IS_SENSITIVE") == true) return

        val text = clip.getItemAt(0).text?.toString() ?: return
        if (text.isEmpty()) return

        val sha256 = sha256Hex(text.toByteArray(Charsets.UTF_8))
        if (sha256 == lastSyncedHash) return
        lastSyncedHash = sha256

        val packet = JSONObject().apply {
            put("type", "CLIPBOARD_EVENT")
            put("contentType", "PLAIN_TEXT")
            put("textValue", text)
            put("contentSha256", sha256)
        }
        P2PDaemonService.broadcastControlFrame(packet)

        if (!clipboardHistory.contains(text)) {
            clipboardHistory.add(0, text)
            if (clipboardHistory.size > 20) clipboardHistory.removeAt(clipboardHistory.size - 1)
        }
        onClipUpdated?.invoke(text)
    }

    /**
     * Sends whatever was copied in another app while LinkMyMac was in the background.
     * Call when the activity gains window focus: that's the only time Android 10+ allows the read.
     * Reading the description doesn't count as reading the clip, so an unchanged timestamp skips
     * the read and Android 12's "pasted from your clipboard" toast.
     */
    fun pushClipboardOnFocus() {
        val stamp = clipboardManager.primaryClipDescription?.timestamp ?: return
        if (stamp != lastSeenClipStamp) pushCurrentClipboardToMac()
    }

    /**
     * -------------------------------------------------------------------------
     * applyIncomingClipFromMac: Inbound Clipboard Update Handler
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Applies text copied on the Mac directly to the Android clipboard.
     * HOW IT DOES IT:
     *   1. Compares incoming `contentSha256` against `lastSyncedHash`.
     *   2. If identical, ignores the event (prevents re-broadcasting Mac's own copy).
     *   3. Sets `lastSyncedHash` to mark this payload as handled.
     *   4. Creates a new `ClipData.newPlainText("LinkMyMac", textValue)` and commits
     *      it into Android's `ClipboardManager`.
     * WHY IT DOES IT: Makes Mac clipboard content instantly pasteable inside any
     *                 Android application.
     * -------------------------------------------------------------------------
     */
    fun applyIncomingClipFromMac(textValue: String, contentSha256: String) {
        if (contentSha256 == lastSyncedHash) return
        lastSyncedHash = contentSha256

        val clip = ClipData.newPlainText("LinkMyMac", textValue)
        clipboardManager.setPrimaryClip(clip)

        if (!clipboardHistory.contains(textValue)) {
            clipboardHistory.add(0, textValue)
            if (clipboardHistory.size > 20) clipboardHistory.removeAt(clipboardHistory.size - 1)
        }
        onClipUpdated?.invoke(textValue)
    }

    /**
     * -------------------------------------------------------------------------
     * sendCustomTextToMac: Outbound Custom String Composer
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Writes arbitrary text to Android clipboard and pushes to Mac.
     * HOW IT DOES IT: Sets ClipData and invokes pushCurrentClipboardToMac().
     * WHY IT DOES IT: Powers the manual clipboard composer on the phone screen.
     * -------------------------------------------------------------------------
     */
    fun sendCustomTextToMac(text: String) {
        if (text.isEmpty()) return
        val clip = ClipData.newPlainText("LinkMyMac", text)
        clipboardManager.setPrimaryClip(clip)
        pushCurrentClipboardToMac()
    }

    /**
     * -------------------------------------------------------------------------
     * sha256Hex: Cryptographic Hash Formatter
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Computes hex-encoded SHA-256 checksum for a byte array.
     * HOW IT DOES IT: Feeds bytes into `MessageDigest.getInstance("SHA-256")` and
     *                 formats each byte into 2-digit lowercase hexadecimal.
     * WHY IT DOES IT: Provides an exact deterministic fingerprint of clipboard strings
     *                 to detect redundant writes without full string comparisons.
     * -------------------------------------------------------------------------
     */
    private fun sha256Hex(bytes: ByteArray): String {
        return MessageDigest.getInstance("SHA-256")
            .digest(bytes)
            .joinToString("") { "%02x".format(it) }
    }
}
