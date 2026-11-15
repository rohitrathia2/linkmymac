package com.linkmymac.android.service

import android.app.Notification
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.ComponentName
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.ConcurrentHashMap

/**
 * =============================================================================
 * LMMNotificationListener: System Notification Mirroring & Remote Action Bridge
 * =============================================================================
 * WHAT IT DOES: Intercepts incoming Android system notifications in real time,
 *               extracts notification metadata, compresses application icons to
 *               WebP, captures interactive `RemoteInput` reply actions, mirrors
 *               them to the macOS companion, and executes remote actions or inline
 *               text replies initiated from macOS.
 * HOW IT DOES IT:
 *   1. Extends Android's `NotificationListenerService` system component.
 *   2. Listens to `onNotificationPosted()` and `onNotificationRemoved()` callbacks.
 *   3. Extracts notification title, body, subtext, app icon, and action descriptors.
 *   4. Caches pending action intents in a thread-safe `ConcurrentHashMap`.
 *   5. Dispatches `NOTIFICATION_EVENT` JSON control frames via `P2PDaemonService`.
 *   6. When receiving a `NOTIFICATION_ACTION` frame from Mac, retrieves the cached
 *      `PendingIntent`, populates the `RemoteInput` bundle with reply text, and
 *      invokes `pendingIntent.send()`.
 * WHY IT DOES IT: Provides full desktop notification mirroring and bi-directional
 *                 quick replies for WhatsApp, Telegram, SMS, and Slack without
 *                 requiring the user to unlock or pick up their physical phone.
 * =============================================================================
 */
class LMMNotificationListener : NotificationListenerService() {

    companion object {
        /** Singleton instance reference for invoking sync from the P2P daemon */
        @Volatile
        var instance: LMMNotificationListener? = null
            private set

        /**
         * Registry mapping "<notification_key>:<action_id>" to original `Notification.Action`
         * references holding interactive PendingIntents and RemoteInput definitions.
         */
        private val actionRegistry = ConcurrentHashMap<String, Notification.Action>()
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        Log.d("LMMNotification", "LMMNotificationListener onCreate() called, instance registered")
    }

    /**
     * -------------------------------------------------------------------------
     * onListenerConnected: System Service Attachment Hook
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Registers the active service instance and synchronizes existing
     *               active notifications.
     * HOW IT DOES IT: Assigns `instance = this` and invokes `syncActiveNotifications()`.
     * WHY IT DOES IT: Called by Android OS when notification listener permission is
     *                 granted or when the listener binds to the notification manager.
     * -------------------------------------------------------------------------
     */
    override fun onListenerConnected() {
        super.onListenerConnected()
        instance = this
        Log.d("LMMNotification", "onListenerConnected called, syncing active notifications")
        syncActiveNotifications()
    }

    /**
     * -------------------------------------------------------------------------
     * onListenerDisconnected: System Service Detachment Hook
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Cleans up internal references when listener unbinds.
     * HOW IT DOES IT: Clears the `actionRegistry` map and resets `instance = null`.
     * WHY IT DOES IT: Prevents leaking memory or referencing stale pending intents
     *                 when access is revoked or OS unbinds the listener.
     * -------------------------------------------------------------------------
     */
    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        actionRegistry.clear()
        instance = null
        Log.d("LMMNotification", "onListenerDisconnected called")
    }

    /**
     * -------------------------------------------------------------------------
     * syncActiveNotifications: Active Notification State Synchronizer
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Iterates through all currently posted notifications on the phone
     *               and broadcasts each one to connected Mac clients.
     * HOW IT DOES IT: Queries `activeNotifications` array from `NotificationListenerService`
     *                 and loops calling `onNotificationPosted(sbn)`.
     * WHY IT DOES IT: When the macOS app connects or reconnects (e.g. after sleep or
     *                 USB re-plug), this restores complete notification history so
     *                 the desktop feed is never empty.
     * -------------------------------------------------------------------------
     */
    fun syncActiveNotifications() {
        try {
            val active = activeNotifications ?: return
            Log.d("LMMNotification", "syncActiveNotifications: found ${active.size} active notifications")
            for (sbn in active) {
                onNotificationPosted(sbn)
            }
        } catch (_: Exception) {}
    }

    /**
     * -------------------------------------------------------------------------
     * clearAllNotifications: Remote Dismiss All Notifications Handler
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Dismisses all clearable notifications from the Android status bar.
     * HOW IT DOES IT:
     *   1. Invokes NotificationListenerService.cancelAllNotifications().
     *   2. Fallback: Iterates activeNotifications and cancels each isClearable entry.
     *   3. Broadcasts an "ALL_CLEARED" notification event back to Mac.
     * WHY IT DOES IT: Mirrors the macOS notification center "Clear All" action
     *                 directly to the physical Android device.
     * -------------------------------------------------------------------------
     */
    fun clearAllNotifications() {
        Log.d("LMMNotification", "clearAllNotifications invoked!")
        try {
            cancelAllNotifications()
        } catch (e: Exception) {
            Log.e("LMMNotification", "cancelAllNotifications failed", e)
        }
        try {
            val active = activeNotifications
            Log.d("LMMNotification", "Active notifications count: ${active?.size}")
            active?.forEach { sbn ->
                Log.d("LMMNotification", "Inspecting notification: ${sbn.key}, isClearable=${sbn.isClearable}")
                if (sbn.isClearable) {
                    cancelNotification(sbn.key)
                }
            }
        } catch (e: Exception) {
            Log.e("LMMNotification", "Iterative cancelNotification failed", e)
        }

        // Notify macOS that all active alerts have been cleared
        val clearedEvent = JSONObject().apply {
            put("type", "NOTIFICATION_EVENT")
            put("eventType", "ALL_CLEARED")
        }
        P2PDaemonService.broadcastControlFrame(clearedEvent)
    }

    /**
     * -------------------------------------------------------------------------
     * dismissNotification: Single Notification Dismissal Handler
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Dismisses a single notification on the phone by its key.
     * HOW IT DOES IT: Calls NotificationListenerService.cancelNotification(key).
     * WHY IT DOES IT: Enables granular 1-click dismissal of individual notification cards.
     * -------------------------------------------------------------------------
     */
    fun dismissNotification(key: String) {
        try {
            cancelNotification(key)
        } catch (_: Exception) {}
    }

    /**
     * -------------------------------------------------------------------------
     * onNotificationPosted: Real-Time Notification Interceptor
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Intercepts newly posted or updated status bar notifications,
     *               extracts text and reply actions, and broadcasts to Mac.
     * HOW IT DOES IT:
     *   1. Filters out ongoing persistent notifications (media playback, timers)
     *      and the LinkMyMac daemon's own status notification.
     *   2. Extracts title, body (`EXTRA_BIG_TEXT` or `EXTRA_TEXT`), and subtext.
     *   3. Resolves the human-readable application label from `PackageManager`.
     *   4. Iterates through `sbn.notification.actions`, registers each action into
     *      `actionRegistry`, and inspects for `RemoteInput` capability.
     *   5. Serializes a `NOTIFICATION_EVENT` packet with WebP app icon base64 and
     *      transmits it via `P2PDaemonService.broadcastControlFrame()`.
     * WHY IT DOES IT: Enables instant notification delivery to macOS desktop banners
     *                 and the LinkMyMac notification tray.
     * -------------------------------------------------------------------------
     */
    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null || sbn.isOngoing) return
        // Avoid mirroring our own foreground daemon status notification
        if (sbn.packageName == packageName) return

        val extras = sbn.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val body = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        val subText = extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString() ?: ""

        if (title.isBlank() && body.isBlank()) return

        val appName = resolveApplicationName(sbn)
        val iconBase64 = extractAppIconBase64(sbn)

        // Extract actions & inline reply capabilities
        val actionsJson = JSONArray()
        sbn.notification.actions?.forEachIndexed { index, action ->
            val actionId = "act_$index"
            val registryKey = "${sbn.key}:$actionId"
            actionRegistry[registryKey] = action

            val remoteInput = action.remoteInputs?.firstOrNull()
            actionsJson.put(JSONObject().apply {
                put("actionId", actionId)
                put("title", action.title?.toString() ?: "Action")
                put("supportsInlineReply", remoteInput != null)
                put("replyPlaceholder", remoteInput?.label?.toString() ?: "Reply...")
            })
        }

        val packet = JSONObject().apply {
            put("type", "NOTIFICATION_EVENT")
            put("eventType", "POSTED")
            put("notificationKey", sbn.key)
            put("packageName", sbn.packageName)
            put("appName", appName)
            put("title", title)
            put("body", body)
            put("subText", subText)
            put("postTimeMs", sbn.postTime)
            put("appIconBase64", iconBase64)
            put("actions", actionsJson)
        }

        P2PDaemonService.broadcastControlFrame(packet)
    }

    /**
     * -------------------------------------------------------------------------
     * onNotificationRemoved: Notification Dismissal Event Handler
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Detects when a notification is dismissed or cleared on the phone.
     * HOW IT DOES IT:
     *   1. Removes any cached actions for `sbn.key` from `actionRegistry`.
     *   2. Emits a `NOTIFICATION_EVENT` with `eventType: "REMOVED"` and `notificationKey`.
     * WHY IT DOES IT: Keeps the macOS notification center in sync, removing banners
     *                 or feed entries that the user already dismissed on the phone.
     * -------------------------------------------------------------------------
     */
    override fun onNotificationRemoved(sbn: StatusBarNotification?) {
        if (sbn == null) return
        // Clean up cached actions for removed notification
        actionRegistry.keys.removeIf { it.startsWith("${sbn.key}:") }

        val packet = JSONObject().apply {
            put("type", "NOTIFICATION_EVENT")
            put("eventType", "REMOVED")
            put("notificationKey", sbn.key)
        }
        P2PDaemonService.broadcastControlFrame(packet)
    }

    /**
     * -------------------------------------------------------------------------
     * executeNotificationAction: Remote Interactive Reply & Action Executor
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Executes a quick reply or button action on behalf of macOS.
     * HOW IT DOES IT:
     *   1. If `dismissOnly` is true, calls `cancelNotification(notificationKey)`.
     *   2. Looks up the original `Notification.Action` in `actionRegistry`.
     *   3. If `inlineReplyText` is present, packages the text into a `Bundle` keyed
     *      by each `RemoteInput.resultKey` and attaches it via `RemoteInput.addResultsToIntent()`.
     *   4. Dispatches `pendingIntent.send(applicationContext, 0, fillInIntent)`.
     * WHY IT DOES IT: Allows Mac users to respond to WhatsApp, Messages, or Slack
     *                 conversations directly from desktop notification reply fields.
     * -------------------------------------------------------------------------
     */
    fun executeNotificationAction(
        notificationKey: String,
        actionId: String,
        inlineReplyText: String?,
        dismissOnly: Boolean
    ): Boolean {
        if (dismissOnly) {
            cancelNotification(notificationKey)
            return true
        }

        val registryKey = "$notificationKey:$actionId"
        val action = actionRegistry[registryKey] ?: return false
        val pendingIntent: PendingIntent = action.actionIntent ?: return false

        return try {
            val fillInIntent = Intent()
            val remoteInputs = action.remoteInputs
            if (!remoteInputs.isNullOrEmpty() && !inlineReplyText.isNullOrEmpty()) {
                val bundle = Bundle()
                for (remoteInput: RemoteInput in remoteInputs) {
                    bundle.putCharSequence(remoteInput.resultKey, inlineReplyText)
                }
                RemoteInput.addResultsToIntent(remoteInputs, fillInIntent, bundle)
            }
            pendingIntent.send(applicationContext, 0, fillInIntent)
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * -------------------------------------------------------------------------
     * resolveApplicationName: Human-Readable App Title Extractor
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Resolves the official, user-facing application name (e.g. "WhatsApp",
     *               "YouTube", "Messages") instead of raw internal package identifiers.
     * HOW IT DOES IT:
     *   1. Queries `packageManager.getApplicationLabel()` via `ApplicationInfo`.
     *   2. If empty or equal to package name, falls back to notification `EXTRA_SUB_TEXT`.
     *   3. If still unknown, uses `formatPackageNameToReadable()` mapping and heuristics.
     * WHY IT DOES IT: Prevents displaying technical strings like "com.whatsapp" or
     *                 "com.google.android.youtube" on desktop notification feeds.
     * -------------------------------------------------------------------------
     */
    private fun resolveApplicationName(sbn: StatusBarNotification): String {
        try {
            val appInfo = packageManager.getApplicationInfo(sbn.packageName, 0)
            val label = packageManager.getApplicationLabel(appInfo).toString()
            if (label.isNotBlank() && label != sbn.packageName) {
                return label
            }
        } catch (_: Exception) {}

        // Fallback 1: Notification subtext (often contains app name on messaging apps)
        val subText = sbn.notification.extras.getCharSequence(Notification.EXTRA_SUB_TEXT)?.toString()
        if (!subText.isNullOrBlank() && !subText.contains(".")) {
            return subText
        }

        // Fallback 2: Domain heuristics and clean dictionary lookup
        return formatPackageNameToReadable(sbn.packageName)
    }

    /**
     * -------------------------------------------------------------------------
     * formatPackageNameToReadable: Package Name to Real App Name Mapper
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Maps popular Android package identifiers to clean, branded app names.
     * HOW IT DOES IT: Performs direct hash lookup against known apps, then applies
     *                 segment capitalization and stripping heuristics.
     * WHY IT DOES IT: Guarantees clean, friendly desktop display even if PackageManager
     *                 metadata cannot be resolved.
     * -------------------------------------------------------------------------
     */
    private fun formatPackageNameToReadable(pkg: String): String {
        val knownApps = mapOf(
            "com.whatsapp" to "WhatsApp",
            "com.whatsapp.w4b" to "WhatsApp Business",
            "com.instagram.android" to "Instagram",
            "com.google.android.youtube" to "YouTube",
            "com.google.android.gm" to "Gmail",
            "com.google.android.apps.messaging" to "Messages",
            "com.android.mms" to "Messages",
            "org.telegram.messenger" to "Telegram",
            "com.twitter.android" to "X (Twitter)",
            "com.facebook.katana" to "Facebook",
            "com.facebook.orca" to "Messenger",
            "com.spotify.music" to "Spotify",
            "com.slack" to "Slack",
            "com.discord" to "Discord",
            "com.google.android.dialer" to "Phone",
            "com.android.dialer" to "Phone",
            "com.android.chrome" to "Chrome",
            "com.google.android.calendar" to "Google Calendar",
            "com.google.android.apps.photos" to "Google Photos",
            "com.snapchat.android" to "Snapchat",
            "com.linkedin.android" to "LinkedIn",
            "com.reddit.frontpage" to "Reddit",
            "com.amazon.mShop.android.shopping" to "Amazon",
            "com.uber.m2" to "Uber",
            "com.ubercab" to "Uber",
            "com.netflix.ninja" to "Netflix",
            "com.netflix.mediaclient" to "Netflix"
        )
        knownApps[pkg]?.let { return it }

        // Heuristic fallback: e.g. "com.example.musicplayer" -> "Musicplayer"
        val segments = pkg.split(".")
        val candidate = segments.lastOrNull()?.replace("android", "", ignoreCase = true)?.trim()
        val base = if (!candidate.isNullOrEmpty()) candidate else segments.getOrNull(segments.size - 2) ?: pkg
        return base.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() }
    }

    /**
     * -------------------------------------------------------------------------
     * extractAppIconBase64: High-Definition App Icon Extractor & PNG Encoder
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Extracts the real official app icon logo (or notification icon)
     *               and compresses it into a high-DPI 96x96 PNG Base64 string.
     * HOW IT DOES IT:
     *   1. Queries `packageManager.getApplicationIcon(sbn.packageName)`.
     *   2. If unavailable, falls back to `sbn.notification.smallIcon?.loadDrawable(this)`
     *      or `sbn.notification.getLargeIcon()?.loadDrawable(this)`.
     *   3. Renders the drawable onto a 96x96 ARGB_8888 bitmap canvas.
     *   4. Encodes bitmap to lossless PNG and converts to Base64 string.
     * WHY IT DOES IT: Delivers sharp, colorful brand logos directly to macOS desktop
     *                 notification banners and UI cards with retina display clarity.
     * -------------------------------------------------------------------------
     */
    private fun extractAppIconBase64(sbn: StatusBarNotification): String {
        return try {
            val drawable = try {
                packageManager.getApplicationIcon(sbn.packageName)
            } catch (_: Exception) {
                sbn.notification.smallIcon?.loadDrawable(this)
                    ?: sbn.notification.getLargeIcon()?.loadDrawable(this)
            } ?: return ""

            val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
                Bitmap.createScaledBitmap(drawable.bitmap, 96, 96, true)
            } else {
                val bmp = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bmp)
                drawable.setBounds(0, 0, canvas.width, canvas.height)
                drawable.draw(canvas)
                bmp
            }
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
        } catch (_: Exception) {
            ""
        }
    }
}
