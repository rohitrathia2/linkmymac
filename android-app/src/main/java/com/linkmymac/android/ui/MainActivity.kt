package com.linkmymac.android.ui

import android.app.Activity
import android.app.KeyguardManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.RippleDrawable
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.text.format.Formatter
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.text.style.ForegroundColorSpan
import android.text.Spanned
import android.text.SpannableStringBuilder
import android.widget.FrameLayout
import android.widget.Switch
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.linkmymac.android.R
import com.linkmymac.android.crypto.CryptoKeystoreManager
import com.linkmymac.android.crypto.PairingManager
import com.linkmymac.android.service.ControlService
import com.linkmymac.android.service.LMMNotificationListener
import com.linkmymac.android.service.P2PDaemonService

/**
 * =============================================================================
 * MainActivity: Companion Device Pairing & Status UI Entry Point
 * =============================================================================
 * WHAT IT DOES:
 *   Serves as the high-fidelity Android user interface for LinkMyMac.
 *   Provides:
 *     1. Hero Status Header with official glowing LinkMyMac branding, live daemon
 *        connection telemetry, Wi-Fi IP and USB ADB forward badges.
 *     2. Interactive Permissions Hub with real-time status badges (Notification
 *        Access, Scoped Storage Gallery Access, Live Continuity Camera).
 *     3. Scannable Cryptographic QR Pairing Card for 1-second Mac camera pairing.
 *     4. Universal Clipboard Live Sync Controller with manual test push.
 *     5. Continuity Ecosystem Feature Matrix overview.
 *
 * HOW IT DOES IT:
 *   - Constructs a bespoke programmatic Material 3 / Glassmorphic layout using
 *     dynamic GradientDrawables, RippleDrawables, and elevation layers without
 *     heavyweight XML themes.
 *   - Hooks into `onResume()` to reactively refresh permission state indicators
 *     the instant the user returns from system settings sheets.
 *   - Interacts with `CryptoKeystoreManager` to encode local TLS fingerprints and
 *     ephemeral nonces into high-contrast QR bitmaps via ZXing.
 *
 * WHY IT DOES IT:
 *   Eliminates complex manual network setups and provides a polished, intuitive
 *   experience matching Apple Continuity and macOS Sequoia aesthetics.
 * =============================================================================
 */
class MainActivity : Activity() {

    private lateinit var cryptoManager: CryptoKeystoreManager
    private lateinit var qrPayloadText: TextView
    private lateinit var qrCodeImageView: ImageView
    private lateinit var pairingCodeText: TextView
    private lateinit var pairingStatusText: TextView
    private lateinit var pairingSection: LinearLayout
    private lateinit var connectedSection: LinearLayout
    private lateinit var connectedTitle: TextView
    private lateinit var connectedDetail: TextView
    private lateinit var notifSwitch: Switch
    private lateinit var storageSwitch: Switch
    private lateinit var cameraSwitch: Switch
    private lateinit var phoneSwitch: Switch
    private lateinit var controlSwitch: Switch
    private var lastShownCode = ""
    private val pickFilesRequest = 201

    // Permission status badge references for dynamic onResume refresh
    private val phonePermissions = arrayOf(
        android.Manifest.permission.READ_SMS,
        android.Manifest.permission.SEND_SMS,
        android.Manifest.permission.READ_CONTACTS,
        android.Manifest.permission.READ_PHONE_STATE,
        android.Manifest.permission.READ_CALL_LOG,
        android.Manifest.permission.ANSWER_PHONE_CALLS,
        android.Manifest.permission.CALL_PHONE
    )
    private lateinit var networkStatusBadge: TextView
    private lateinit var ipPillText: TextView

    // Camera live controls
    private lateinit var camStreamStatusBadge: TextView
    private lateinit var camLensBadge: TextView
    private lateinit var btnFlipCamera: Button
    private lateinit var btnToggleStream: Button

    // Mac Now Playing Media UI references
    private lateinit var mediaStatusBadge: TextView
    private lateinit var mediaTitleText: TextView
    private lateinit var mediaSubtitleText: TextView
    private lateinit var btnMediaPrev: Button
    private lateinit var btnMediaPlayPause: Button
    private lateinit var btnMediaNext: Button

    // Universal Clipboard Hub
    private lateinit var currentClipDisplay: TextView
    private lateinit var clipInputText: EditText
    private lateinit var historyItemsLayout: LinearLayout

    // Dynamic Automatic Refresh Engine
    private val autoRefreshHandler = Handler(Looper.getMainLooper())
    private var autoRefreshRunnable: Runnable? = null
    private var primaryClipListener: ClipboardManager.OnPrimaryClipChangedListener? = null
    private var lastKnownIp: String = ""
    private var lastObservedClip: String = ""
    private var livePlaybackElapsed: Double = 0.0
    private var lastPlaybackUpdateTime: Long = 0L

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
    private fun dp(value: Float): Float = value * resources.displayMetrics.density

    /**
     * -------------------------------------------------------------------------
     * generateQrBitmap: Cryptographic QR Code Matrix & Bitmap Generator
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Encodes an arbitrary text payload into a square QR barcode bitmap.
     * HOW IT DOES IT: Uses ZXing QRCodeWriter with UTF-8 encoding and minimal padding,
     *                 iterating over the BitMatrix to generate a RGB_565 Bitmap.
     * WHY IT DOES IT: Allows macOS clients to scan the pairing token out-of-band using
     *                 their Mac camera or screenshot importer.
     * -------------------------------------------------------------------------
     */
    private fun generateQrBitmap(content: String, sizePx: Int = 512): Bitmap {
        return try {
            val hints = mapOf(
                EncodeHintType.MARGIN to 1,
                EncodeHintType.CHARACTER_SET to "UTF-8"
            )
            val matrix = QRCodeWriter().encode(
                content,
                BarcodeFormat.QR_CODE,
                sizePx,
                sizePx,
                hints
            )
            val width = matrix.width
            val height = matrix.height
            val bmp = Bitmap.createBitmap(width, height, Bitmap.Config.RGB_565)
            for (x in 0 until width) {
                for (y in 0 until height) {
                    bmp.setPixel(x, y, if (matrix[x, y]) Color.parseColor("#0B0D17") else Color.WHITE)
                }
            }
            bmp
        } catch (_: Exception) {
            Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.RGB_565)
        }
    }

    private fun updateQrDisplay() {
        val payload = cryptoManager.buildPairingQrPayload(
            deviceName = "${Build.MANUFACTURER} ${Build.MODEL}",
            port = P2PDaemonService.DEFAULT_PORT
        )
        qrPayloadText.text = payload
        val qrBitmap = generateQrBitmap(payload, 512)
        qrCodeImageView.setImageBitmap(qrBitmap)
    }

    private fun formattedPairingCode(): String =
        PairingManager.pairingCode.let { "${it.take(3)} ${it.drop(3)}" }

    /** Codes are single use, so re-render the code and QR whenever a pairing rotates it. */
    private fun updatePairingUi() {
        if (!::pairingCodeText.isInitialized) return
        val code = PairingManager.pairingCode
        if (code != lastShownCode) {
            lastShownCode = code
            pairingCodeText.text = formattedPairingCode()
            pairingCodeText.contentDescription = "Pairing code " + code.toList().joinToString(" ")
            updateQrDisplay()
        }
        val paired = PairingManager.pairedMacCount(this)
        pairingStatusText.text = when (paired) {
            0 -> "No Mac paired yet"
            1 -> "1 Mac paired"
            else -> "$paired Macs paired"
        }
    }

    /** Share sheet → Mac. Files are streamed; shared text or links go to the Mac clipboard. */
    private fun handleShareIntent(intent: Intent) {
        @Suppress("DEPRECATION")
        val uris: List<Uri> = if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
        } else {
            listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM))
        }
        if (uris.isNotEmpty()) {
            sendFilesToMac(uris)
            return
        }
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val clipboard = P2PDaemonService.activeClipboardHelper
        val message = if (!text.isNullOrBlank() && clipboard != null && P2PDaemonService.isMacConnected) {
            clipboard.sendCustomTextToMac(text)
            "Sent to your Mac's clipboard"
        } else {
            "No paired Mac connected"
        }
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    private fun sendFilesToMac(uris: List<Uri>) {
        val message = if (P2PDaemonService.sendFilesToMac(uris)) {
            if (uris.size == 1) "Sending to your Mac…" else "Sending ${uris.size} files to your Mac…"
        } else {
            "No paired Mac connected. Open LinkMyMac on your Mac first."
        }
        Toast.makeText(this, message, Toast.LENGTH_LONG).show()
    }

    private fun pickFilesForMac() {
        val pick = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        @Suppress("DEPRECATION")
        startActivityForResult(pick, pickFilesRequest)
    }

    @Deprecated("Framework Activity result API; this app doesn't use AndroidX Activity.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickFilesRequest || resultCode != RESULT_OK || data == null) return
        val clip = data.clipData
        val uris = if (clip != null) (0 until clip.itemCount).map { clip.getItemAt(it).uri } else listOfNotNull(data.data)
        if (uris.isNotEmpty()) sendFilesToMac(uris)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE) {
            handleShareIntent(intent)
        }
    }

    private fun getLocalWifiIpAddress(): String {
        return try {
            val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            Formatter.formatIpAddress(wm.connectionInfo.ipAddress)
        } catch (_: Exception) {
            "127.0.0.1"
        }
    }

    private fun isNotificationAccessGranted(): Boolean {
        val enabledListeners = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
        val myComponent = "$packageName/${LMMNotificationListener::class.java.name}"
        return enabledListeners != null && enabledListeners.contains(myComponent)
    }

    private fun isStorageAccessGranted(): Boolean {
        return if (Build.VERSION.SDK_INT >= 30) {
            Environment.isExternalStorageManager() ||
            checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        } else {
            checkSelfPermission(android.Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun isCameraAccessGranted(): Boolean {
        return checkSelfPermission(android.Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
    }

    /**
     * -------------------------------------------------------------------------
     * updateAllPermissionStates: Live Permission Observer
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Checks the live grant status of Notifications, Storage and Camera.
     * HOW IT DOES IT: Updates pill badge color (Green = Active, Amber = Action Required)
     *                 and enables/disables the action button.
     * WHY IT DOES IT: Gives the user immediate visual feedback when returning from
     *                 Android system settings.
     * -------------------------------------------------------------------------
     */
    private fun updateAllPermissionStates() {
        if (!::notifSwitch.isInitialized) return
        notifSwitch.isChecked = isNotificationAccessGranted()
        storageSwitch.isChecked = isStorageAccessGranted()
        cameraSwitch.isChecked = isCameraAccessGranted()
        phoneSwitch.isChecked = phonePermissions.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
        controlSwitch.isChecked = ControlService.instance != null
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 103) P2PDaemonService.onPermissionsChanged() // start SMS observer + call listener
        updateAllPermissionStates()
    }

    /**
     * -------------------------------------------------------------------------
     * updateCameraCardState: Live Reactive Camera State Reflector
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Updates the camera stream status badge, lens badge, and buttons.
     * HOW IT DOES IT: Checks whether the stream is active or switching lenses,
     *                 applying appropriate high-contrast color pills.
     * WHY IT DOES IT: Reflects camera changes triggered on either Android or Mac.
     * -------------------------------------------------------------------------
     */
    private fun updateCameraCardState(lens: String, isStreaming: Boolean, isSwitching: Boolean) {
        if (!::camStreamStatusBadge.isInitialized || !::camLensBadge.isInitialized) return

        if (isStreaming) {
            camStreamStatusBadge.text = "● LIVE STREAMING"
            camStreamStatusBadge.background = createPillDrawable("#123222", "#3DDC84")
            camStreamStatusBadge.setTextColor(Color.parseColor("#3DDC84"))
            if (::btnToggleStream.isInitialized) {
                btnToggleStream.text = "⏹ Stop Live Stream"
            }
        } else {
            camStreamStatusBadge.text = "○ STANDBY"
            camStreamStatusBadge.background = createPillDrawable("#20243A", "#6F7593")
            camStreamStatusBadge.setTextColor(Color.parseColor("#A6ACC4"))
            if (::btnToggleStream.isInitialized) {
                btnToggleStream.text = "▶ Start Live Stream"
            }
        }

        val isFront = lens.equals("FRONT", ignoreCase = true)
        if (isSwitching) {
            camLensBadge.text = "🔄 SWITCHING..."
            camLensBadge.background = createPillDrawable("#3A2B0C", "#F6B84B")
            camLensBadge.setTextColor(Color.parseColor("#F6B84B"))
        } else if (isFront) {
            camLensBadge.text = "🤳 FRONT (FACETIME HD)"
            camLensBadge.background = createPillDrawable("#232859", "#8F98FF")
            camLensBadge.setTextColor(Color.parseColor("#C3C8FF"))
        } else {
            camLensBadge.text = "📷 BACK (MAIN 4K)"
            camLensBadge.background = createPillDrawable("#232859", "#8F98FF")
            camLensBadge.setTextColor(Color.parseColor("#C3C8FF"))
        }
    }

    /**
     * -------------------------------------------------------------------------
     * updateClipboardUi: Live Reactive Clipboard Hub Synchronizer
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Populates the active clipboard text box and recent history list.
     * HOW IT DOES IT: Inspects ClipboardSyncHelper's in-memory history and Android OS clip.
     * WHY IT DOES IT: Gives the user full visibility and 1-tap copy access on Android.
     * -------------------------------------------------------------------------
     */
    private fun updateClipboardUi() {
        if (!::currentClipDisplay.isInitialized) return
        val helper = P2PDaemonService.activeClipboardHelper
        val history = helper?.clipboardHistory ?: emptyList<String>()
        val latest = if (history.isNotEmpty()) {
            history.first()
        } else {
            try {
                val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
                cm.primaryClip?.getItemAt(0)?.text?.toString() ?: ""
            } catch (_: Exception) {
                ""
            }
        }

        if (latest.isNotBlank()) {
            lastObservedClip = latest
            currentClipDisplay.text = latest
            currentClipDisplay.setTextColor(Color.parseColor("#F3F4FA"))
        } else {
            lastObservedClip = ""
            currentClipDisplay.text = "No clipboard items synced yet. Copy text on Mac or type below."
            currentClipDisplay.setTextColor(Color.parseColor("#6F7593"))
        }

        if (::historyItemsLayout.isInitialized) {
            historyItemsLayout.removeAllViews()
            if (history.isEmpty()) {
                val emptyTv = TextView(this).apply {
                    text = "History appears here as you copy on phone or Mac."
                    textSize = 11f
                    setTextColor(Color.parseColor("#6F7593"))
                    setPadding(0, dp(4), 0, dp(4))
                }
                historyItemsLayout.addView(emptyTv)
            } else {
                for (item in history.take(5)) {
                    val row = LinearLayout(this).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = Gravity.CENTER_VERTICAL
                        setPadding(dp(10), dp(8), dp(10), dp(8))
                        background = GradientDrawable().apply {
                            setColor(Color.parseColor("#0B0D17"))
                            cornerRadius = dp(8f)
                            setStroke(dp(1), Color.parseColor("#20243A"))
                        }
                        layoutParams = LinearLayout.LayoutParams(
                            LinearLayout.LayoutParams.MATCH_PARENT,
                            LinearLayout.LayoutParams.WRAP_CONTENT
                        ).apply {
                            bottomMargin = dp(6)
                        }
                    }

                    val previewText = TextView(this).apply {
                        text = if (item.length > 50) item.take(50) + "…" else item
                        textSize = 12f
                        setTextColor(Color.parseColor("#F3F4FA"))
                        typeface = Typeface.MONOSPACE
                        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
                    }
                    row.addView(previewText)

                    val btnCopyItem = createModernButton(
                        text = "Copy",
                        bgColor = "#20243A",
                        textColor = "#8F98FF"
                    ) {
                        val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
                        cm.setPrimaryClip(ClipData.newPlainText("LinkMyMac", item))
                        Toast.makeText(this@MainActivity, "Copied to clipboard!", Toast.LENGTH_SHORT).show()
                    }.apply {
                        setPadding(dp(10), dp(4), dp(10), dp(4))
                        textSize = 10f
                    }
                    row.addView(btnCopyItem)
                    historyItemsLayout.addView(row)
                }
            }
        }
    }

    /**
     * -------------------------------------------------------------------------
     * updateNetworkState: Live Reactive Daemon & Mac Client Status Reflector
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Automatically refreshes Wi-Fi IP display, QR pairing barcode,
     *               and connected Mac count without manual user intervention.
     * HOW IT DOES IT: Queries WifiManager IP and P2PDaemonService client count.
     * WHY IT DOES IT: Keeps the status header 100% accurate at all times.
     * -------------------------------------------------------------------------
     */
    private fun updateNetworkState(clientCount: Int = P2PDaemonService.connectedClientCount) {
        if (!::networkStatusBadge.isInitialized || !::ipPillText.isInitialized) return

        val wifiIp = getLocalWifiIpAddress()
        if (wifiIp != lastKnownIp) {
            lastKnownIp = wifiIp
            ipPillText.text = "Visible on Wi‑Fi as ${Build.MODEL} · $wifiIp"
            if (::qrPayloadText.isInitialized && ::qrCodeImageView.isInitialized) {
                updateQrDisplay()
            }
        }

        val connected = clientCount > 0
        setChip(networkStatusBadge, if (connected) "Connected" else "Listening", if (connected) "success" else "neutral")
        pairingSection.visibility = if (connected) View.GONE else View.VISIBLE
        connectedSection.visibility = if (connected) View.VISIBLE else View.GONE
        connectedTitle.text = "Connected to ${P2PDaemonService.connectedMacName ?: "your Mac"}"
        connectedDetail.text = if (clientCount > 1) "$clientCount Macs connected" else "Paired and connected"
    }

    /**
     * -------------------------------------------------------------------------
     * performDynamicAutoRefresh: 1-Second Background UI Watchdog Tick
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Dynamically and automatically refreshes all permissions,
     *               network IP changes, Mac connection status, clipboard updates,
     *               and live media playback progress without any manual refresh taps.
     * HOW IT DOES IT: Triggered every 1000ms by `autoRefreshHandler`.
     * WHY IT DOES IT: Eliminates all need for manual refresh throughout the app.
     * -------------------------------------------------------------------------
     */
    private fun performDynamicAutoRefresh() {
        updateAllPermissionStates()
        updateNetworkState()
        updatePairingUi()
        tickLiveMediaProgress()

        // Dynamic local clipboard change check
        try {
            val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
            val text = cm.primaryClip?.getItemAt(0)?.text?.toString() ?: ""
            if (text.isNotBlank() && text != lastObservedClip) {
                updateClipboardUi()
            }
        } catch (_: Exception) {}
    }

    private fun tickLiveMediaProgress() {
        if (!::mediaSubtitleText.isInitialized) return
        val helper = P2PDaemonService.activeMediaNotificationHelper ?: return
        val data = helper.currentData
        if (!data.hasMedia || !data.isPlaying || data.duration <= 0.0) return

        val now = SystemClock.elapsedRealtime()
        if (lastPlaybackUpdateTime > 0L) {
            val deltaSeconds = (now - lastPlaybackUpdateTime) / 1000.0
            livePlaybackElapsed += deltaSeconds
            if (livePlaybackElapsed > data.duration) {
                livePlaybackElapsed = data.duration
            }
        }
        lastPlaybackUpdateTime = now

        val curM = (livePlaybackElapsed.toInt()) / 60
        val curS = (livePlaybackElapsed.toInt()) % 60
        val totM = (data.duration.toInt()) / 60
        val totS = (data.duration.toInt()) % 60
        val app = if (data.appName.isNotEmpty()) " (${data.appName})" else ""
        val sub = if (data.artist.isNotEmpty()) "${data.artist}$app • " else ""
        mediaSubtitleText.text = String.format("%s%02d:%02d / %02d:%02d", sub, curM, curS, totM, totS)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Android 10+ only lets the focused app read the clipboard: send what was copied elsewhere.
        if (hasFocus) P2PDaemonService.activeClipboardHelper?.pushClipboardOnFocus()
    }

    override fun onResume() {
        super.onResume()
        updateAllPermissionStates()
        updateNetworkState()

        // 1. Hook up Primary Clipboard Listener for instant real-time sync
        try {
            val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
            val listener = ClipboardManager.OnPrimaryClipChangedListener {
                runOnUiThread {
                    updateClipboardUi()
                }
            }
            primaryClipListener = listener
            cm.addPrimaryClipChangedListener(listener)
        } catch (_: Exception) {}

        // 2. Hook up P2P Client Count Observer
        P2PDaemonService.onClientCountChanged = { count ->
            runOnUiThread {
                updateNetworkState(count)
            }
        }

        // 3. Hook up Camera State Observer
        P2PDaemonService.activeCameraProvider?.let { provider ->
            updateCameraCardState(provider.getCurrentLens(), provider.isStreaming(), provider.isSwitching())
            provider.onCameraStateChanged = { lens, isStreaming, isSwitching ->
                runOnUiThread {
                    updateCameraCardState(lens, isStreaming, isSwitching)
                }
            }
        }

        // 4. Hook up Clipboard State Observer
        P2PDaemonService.activeClipboardHelper?.let { helper ->
            updateClipboardUi()
            helper.onClipUpdated = { _ ->
                runOnUiThread {
                    updateClipboardUi()
                }
            }
        }

        // 5. Hook up Mac Now Playing Media State Observer
        P2PDaemonService.activeMediaNotificationHelper?.let { helper ->
            updateMediaCardState(helper.currentData)
            helper.onNowPlayingChanged = { data ->
                runOnUiThread {
                    updateMediaCardState(data)
                }
            }
        }

        // 6. Start Dynamic Automatic Refresh Loop (1-second tick)
        autoRefreshRunnable?.let { autoRefreshHandler.removeCallbacks(it) }
        val runnable = object : Runnable {
            override fun run() {
                performDynamicAutoRefresh()
                autoRefreshHandler.postDelayed(this, 1000)
            }
        }
        autoRefreshRunnable = runnable
        autoRefreshHandler.post(runnable)
    }

    override fun onPause() {
        super.onPause()
        autoRefreshRunnable?.let { autoRefreshHandler.removeCallbacks(it) }
        autoRefreshRunnable = null

        primaryClipListener?.let {
            try {
                val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
                cm.removePrimaryClipChangedListener(it)
            } catch (_: Exception) {}
        }
        primaryClipListener = null
        P2PDaemonService.onClientCountChanged = null
    }

    /**
     * -------------------------------------------------------------------------
     * updateMediaCardState: Live Reactive Mac Now Playing State Reflector
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Updates in-app media player card with current title, artist,
     *               playback status badge, and Play/Pause button text.
     * HOW IT DOES IT: Reads NowPlayingData from MediaNotificationHelper.
     * WHY IT DOES IT: User requested media control to appear inside the app as
     *                 well as on the notification panel.
     * -------------------------------------------------------------------------
     */
    private fun updateMediaCardState(data: com.linkmymac.android.service.MediaNotificationHelper.NowPlayingData) {
        if (!::mediaStatusBadge.isInitialized || !::mediaTitleText.isInitialized) return

        if (!data.hasMedia || data.title.isBlank()) {
            livePlaybackElapsed = 0.0
            lastPlaybackUpdateTime = 0L
            mediaStatusBadge.text = "○ STANDBY"
            mediaStatusBadge.background = createPillDrawable("#20243A", "#6F7593")
            mediaStatusBadge.setTextColor(Color.parseColor("#A6ACC4"))
            mediaTitleText.text = "No active media playing on Mac"
            mediaTitleText.setTextColor(Color.parseColor("#A6ACC4"))
            mediaSubtitleText.text = "Start audio or video on Mac (Spotify, YouTube, Apple Music) to control it here and in your notifications."
            btnMediaPlayPause.text = "▶ Play"
            btnMediaPlayPause.isEnabled = false
            btnMediaPrev.isEnabled = false
            btnMediaNext.isEnabled = false
        } else {
            livePlaybackElapsed = data.elapsedTime
            lastPlaybackUpdateTime = SystemClock.elapsedRealtime()
            btnMediaPlayPause.isEnabled = true
            btnMediaPrev.isEnabled = true
            btnMediaNext.isEnabled = true
            mediaTitleText.text = data.title
            mediaTitleText.setTextColor(Color.WHITE)

            val timeStr = if (data.duration > 0.0) {
                val curM = (data.elapsedTime.toInt()) / 60
                val curS = (data.elapsedTime.toInt()) % 60
                val totM = (data.duration.toInt()) / 60
                val totS = (data.duration.toInt()) % 60
                String.format(" • %02d:%02d / %02d:%02d", curM, curS, totM, totS)
            } else ""
            val app = if (data.appName.isNotEmpty()) " (${data.appName})" else ""
            val sub = if (data.artist.isNotEmpty() && data.album.isNotEmpty()) {
                "${data.artist} — ${data.album}$app"
            } else if (data.artist.isNotEmpty()) {
                "${data.artist}$app"
            } else {
                "Mac Audio / Video$app"
            }
            mediaSubtitleText.text = sub + timeStr

            if (data.isPlaying) {
                mediaStatusBadge.text = "● PLAYING ON MAC"
                mediaStatusBadge.background = createPillDrawable("#123222", "#3DDC84")
                mediaStatusBadge.setTextColor(Color.parseColor("#3DDC84"))
                btnMediaPlayPause.text = "⏸ Pause"
            } else {
                mediaStatusBadge.text = "⏸ PAUSED ON MAC"
                mediaStatusBadge.background = createPillDrawable("#3A2B0C", "#F6B84B")
                mediaStatusBadge.setTextColor(Color.parseColor("#F6B84B"))
                btnMediaPlayPause.text = "▶ Resume"
            }
        }
    }

    /**
     * -------------------------------------------------------------------------
     * onCreate: Activity Lifecycle & Modern UI Builder
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Initializes cryptographic providers, starts the background
     *               daemon service, and inflates the complete modern UI hierarchy.
     * HOW IT DOES IT:
     *   1. Enables FLAG_KEEP_SCREEN_ON to prevent device sleeping during sessions.
     *   2. Dispatches startForegroundService(P2PDaemonService).
     *   3. Programmatically constructs a dark Material 3 dashboard layout with
     *      Glassmorphic cards, glowing LinkMyMac logo, status pills, and QR card.
     * WHY IT DOES IT: Provides a unified, ultra-responsive native UI on Android.
     * -------------------------------------------------------------------------
     */
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Opened from another app's share sheet: send, then return to that app.
        if (intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE) {
            handleShareIntent(intent)
            finish()
            return
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.statusBarColor = Color.parseColor("#0B0D17")
        window.navigationBarColor = Color.parseColor("#0B0D17")

        /**
         * WHAT IT DOES: Allows MainActivity to display above keyguard lockscreen and keeps display awake.
         * HOW IT DOES IT: Uses setShowWhenLocked(true), setTurnScreenOn(true), and requestDismissKeyguard.
         * WHY IT DOES IT: Prevents Android CameraService from locking down camera hardware with
         *                 "Camera disabled by policy (code 6)" when device is locked on desk during Continuity Camera streaming.
         */
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
            keyguardManager?.requestDismissKeyguard(this, null)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }

        cryptoManager = CryptoKeystoreManager()

        // Persistent Daemon Bootstrapping
        val serviceIntent = Intent(this, P2PDaemonService::class.java)
        startForegroundService(serviceIntent)

        // Root Scrollable Canvas
        val scroll = ScrollView(this).apply {
            setBackgroundColor(Color.parseColor("#0B0D17"))
            isFillViewport = true
        }
        // Android 15+ draws apps edge to edge: keep content clear of the status and gesture bars.
        scroll.setOnApplyWindowInsetsListener { view, insets ->
            @Suppress("DEPRECATION") val bars = insets.systemWindowInsets // API 29+: status + navigation bars
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(24), dp(16), dp(32))
        }

        // =====================================================================
        // Top app bar, then the pairing or connected card
        // (Figma: Android · Pairing code / Android · Connected)
        // =====================================================================
        val appBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(4), 0, 0, dp(16))
        }
        appBar.addView(brandMark(32))
        appBar.addView(lmText("LinkMyMac", 18f, LM.TEXT, medium = true).apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = dp(12) }
        })
        networkStatusBadge = lmChip()
        appBar.addView(networkStatusBadge)
        root.addView(appBar)

        // Pairing: the code to type on the Mac, the QR alternative, what the Mac sees.
        pairingSection = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val pairHero = lmCard(28f, 24, 24).apply { gravity = Gravity.CENTER_HORIZONTAL }
        pairHero.addView(lmChip().also { setChip(it, "Ready to pair", "brand") }, wrap())
        pairHero.addView(lmText("Pair with your Mac", 24f, LM.TEXT, medium = true).apply {
            gravity = Gravity.CENTER
            setPadding(0, dp(16), 0, 0)
        })
        pairHero.addView(lmText("Open LinkMyMac on your Mac, pick this phone, then type:", 14f, LM.TEXT2).apply {
            gravity = Gravity.CENTER
            setPadding(dp(8), dp(8), dp(8), 0)
            setLineSpacing(dp(2f), 1f)
        })
        pairingCodeText = TextView(this).apply {
            textSize = 36f
            typeface = Typeface.MONOSPACE
            letterSpacing = 0.12f
            setTextColor(c(LM.TEXT))
            gravity = Gravity.CENTER
            background = roundRect(LM.SURFACE_MUTED, 20f, LM.BORDER)
            setPadding(dp(22), dp(12), dp(22), dp(12))
        }
        pairHero.addView(pairingCodeText, wrap(top = 16))
        pairHero.addView(lmTextButton("New code", R.drawable.ic_lm_refresh, LM.BRAND) {
            cryptoManager.rotateEphemeralNonce()
            PairingManager.rotateCode()
            updatePairingUi()
            Toast.makeText(this@MainActivity, "New pairing code", Toast.LENGTH_SHORT).show()
        }, wrap(top = 8))
        pairingStatusText = lmText("", 12f, LM.TEXT3).apply { gravity = Gravity.CENTER }
        pairHero.addView(pairingStatusText, wrap())
        pairingSection.addView(pairHero, matchWrap())

        val qrCard = lmCard(24f, 16, 16).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val qrTile = FrameLayout(this).apply {
            background = roundRect("#FFFFFF", 12f)
            setPadding(dp(6), dp(6), dp(6), dp(6))
        }
        qrCodeImageView = ImageView(this)
        qrTile.addView(qrCodeImageView, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
        qrCard.addView(qrTile, LinearLayout.LayoutParams(dp(84), dp(84)))
        val qrTexts = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        qrTexts.addView(lmText("Or scan it with your Mac’s camera", 16f, LM.TEXT, medium = true))
        qrTexts.addView(lmText("For when your Mac can’t find this phone", 14f, LM.TEXT2).apply { setPadding(0, dp(2), 0, 0) })
        qrTexts.addView(lmTextButton("Copy pairing text", null, LM.BRAND) {
            val cm = getSystemService(CLIPBOARD_SERVICE) as android.content.ClipboardManager
            cm.setPrimaryClip(android.content.ClipData.newPlainText("LinkMyMac pairing", qrPayloadText.text))
            Toast.makeText(this@MainActivity, "Pairing text copied", Toast.LENGTH_SHORT).show()
        }.apply { setPadding(0, dp(8), dp(8), dp(4)) }, wrap())
        qrCard.addView(qrTexts, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = dp(14) })
        pairingSection.addView(qrCard, matchWrap(top = 12))

        val visibilityRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = roundRect(LM.SURFACE_MUTED, 20f)
            setPadding(dp(16), dp(12), dp(16), dp(12))
        }
        visibilityRow.addView(iconView(R.drawable.ic_lm_wifi, 18, LM.SUCCESS))
        ipPillText = lmText("", 14f, LM.TEXT2).apply { setPadding(dp(10), 0, 0, 0) }
        visibilityRow.addView(ipPillText)
        pairingSection.addView(visibilityRow, matchWrap(top = 12))
        qrPayloadText = TextView(this) // the QR's text form, for "Copy pairing text"
        root.addView(pairingSection, matchWrap())

        // Connected: which Mac, and a way to unpair.
        connectedSection = lmCard(28f, 24, 20).apply {
            gravity = Gravity.CENTER_HORIZONTAL
            visibility = View.GONE
        }
        val checkBadge = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(c(LM.SUCCESS_SOFT))
            }
            addView(iconView(R.drawable.ic_lm_check, 32, LM.SUCCESS).apply {
                layoutParams = FrameLayout.LayoutParams(dp(32), dp(32), Gravity.CENTER)
            })
        }
        connectedSection.addView(checkBadge, LinearLayout.LayoutParams(dp(64), dp(64)))
        connectedTitle = lmText("Connected to your Mac", 24f, LM.TEXT, medium = true).apply {
            gravity = Gravity.CENTER
            setPadding(0, dp(12), 0, 0)
        }
        connectedSection.addView(connectedTitle)
        connectedDetail = lmText("", 14f, LM.TEXT2).apply {
            gravity = Gravity.CENTER
            setPadding(0, dp(4), 0, 0)
        }
        connectedSection.addView(connectedDetail)
        connectedSection.addView(lmTextButton("Unpair from Mac", R.drawable.ic_lm_unlink, LM.DANGER) {
            PairingManager.forgetAllMacs(this@MainActivity)
            P2PDaemonService.disconnectAllClients()
            updatePairingUi()
            Toast.makeText(this@MainActivity, "Unpaired. Your Mac will need the code to reconnect.", Toast.LENGTH_SHORT).show()
        }, wrap(top = 8))
        root.addView(connectedSection, matchWrap())

        // What the Mac can use: each switch shows whether Android allows it; tap to change.
        root.addView(createSectionHeader("Shared with your Mac"))
        val features = lmCard(24f, 0, 4)
        fun featureRow(icon: Int, title: String, detail: String, onTap: () -> Unit): Switch {
            val row = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(16), dp(10), dp(16), dp(10))
                isClickable = true
                background = RippleDrawable(ColorStateList.valueOf(c("#22FFFFFF")), null, roundRect("#FFFFFF", 0f))
                setOnClickListener { onTap() }
            }
            row.addView(iconTile(icon, 40, 22, LM.BRAND_SOFT, LM.BRAND, 12f))
            val texts = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
            texts.addView(lmText(title, 16f, LM.TEXT, medium = true))
            texts.addView(lmText(detail, 14f, LM.TEXT2))
            row.addView(texts, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = dp(14) })
            val states = arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf())
            val toggle = Switch(this).apply {
                isClickable = false
                isFocusable = false
                thumbTintList = ColorStateList(states, intArrayOf(c(LM.ON_BRAND), c(LM.TEXT3)))
                trackTintList = ColorStateList(states, intArrayOf(c(LM.BRAND), c("#3B4262")))
            }
            row.addView(toggle)
            features.addView(row, matchWrap())
            return toggle
        }
        val openAppSettings = {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
        }
        notifSwitch = featureRow(R.drawable.ic_lm_bell, "Notifications", "Mirrored on your Mac") {
            startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        }
        storageSwitch = featureRow(R.drawable.ic_lm_photo, "Photos & videos", "Browse and stream from your Mac") {
            if (isStorageAccessGranted()) {
                openAppSettings()
            } else if (Build.VERSION.SDK_INT >= 30) {
                try {
                    startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                } catch (_: Exception) {
                    requestPermissions(arrayOf(android.Manifest.permission.READ_EXTERNAL_STORAGE), 101)
                }
            } else {
                requestPermissions(arrayOf(android.Manifest.permission.READ_EXTERNAL_STORAGE), 101)
            }
        }
        phoneSwitch = featureRow(R.drawable.ic_lm_message, "Messages & calls", "Text and answer from your Mac") {
            if (phonePermissions.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) openAppSettings()
            else requestPermissions(phonePermissions, 103)
        }
        cameraSwitch = featureRow(R.drawable.ic_lm_camera, "Camera", "Live view on your Mac") {
            if (isCameraAccessGranted()) openAppSettings()
            else requestPermissions(arrayOf(android.Manifest.permission.CAMERA), 102)
        }
        controlSwitch = featureRow(R.drawable.ic_lm_pointer, "Mac Control", "Your Mac’s mouse and keyboard") {
            startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }
        root.addView(features, matchWrap())

        // =====================================================================
        // Scope 2.5: Continuity Camera Live Hardware Controller
        // =====================================================================
        // WHAT IT DOES: Lets user switch between Front and Back cameras right on phone
        //               and see live streaming status during video calls (FaceTime,
        //               Google Meet, WhatsApp, Microsoft Teams).
        // HOW IT DOES IT: Interacts with P2PDaemonService.activeCameraProvider to
        //                 invoke switchLens() and update status badges.
        // WHY IT DOES IT: Fulfills user request to toggle camera directly from phone UI
        //                 as well as from Mac during calls.
        // =====================================================================
        val camControlCard = createCardContainer()

        val camControlHeaderRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, 0, dp(8))
        }

        val camControlTitle = TextView(this).apply {
            text = "🎥 Continuity Camera Controls"
            textSize = 15f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.WHITE)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        camControlHeaderRow.addView(camControlTitle)

        camStreamStatusBadge = TextView(this).apply {
            text = "○ STANDBY"
            textSize = 10f
            typeface = Typeface.DEFAULT_BOLD
            setPadding(dp(8), dp(3), dp(8), dp(3))
            background = createPillDrawable("#20243A", "#6F7593")
            setTextColor(Color.parseColor("#A6ACC4"))
        }
        camControlHeaderRow.addView(camStreamStatusBadge)
        camControlCard.addView(camControlHeaderRow)

        val camBadgeRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, 0, dp(12))
        }

        val activeLensLabel = TextView(this).apply {
            text = "ACTIVE LENS:"
            textSize = 11f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.parseColor("#A6ACC4"))
            setPadding(0, 0, dp(8), 0)
        }
        camBadgeRow.addView(activeLensLabel)

        camLensBadge = TextView(this).apply {
            text = "📷 BACK (MAIN 4K)"
            textSize = 10f
            typeface = Typeface.DEFAULT_BOLD
            setPadding(dp(8), dp(3), dp(8), dp(3))
            background = createPillDrawable("#232859", "#8F98FF")
            setTextColor(Color.parseColor("#C3C8FF"))
        }
        camBadgeRow.addView(camLensBadge)
        camControlCard.addView(camBadgeRow)

        val camControlDesc = TextView(this).apply {
            text = "Switch between Front (FaceTime HD) and Back (Main 4K) cameras during video calls on Mac (FaceTime, WhatsApp, Teams, Google Meet). Flipping updates instantly on Mac."
            textSize = 12f
            setTextColor(Color.parseColor("#A6ACC4"))
            setLineSpacing(dp(2f), 1f)
            setPadding(0, 0, 0, dp(14))
        }
        camControlCard.addView(camControlDesc)

        val camBtnRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }

        btnFlipCamera = createModernButton(
            text = "🔄 Switch Lens (Front ⇄ Back)",
            bgColor = "#8F98FF",
            textColor = "#FFFFFF"
        ) {
            val provider = P2PDaemonService.activeCameraProvider
            if (provider != null) {
                val current = provider.getCurrentLens()
                val nextLens = if (current.equals("BACK", ignoreCase = true)) "FRONT" else "BACK"
                if (!provider.isStreaming()) {
                    provider.startStream(nextLens)
                    Toast.makeText(this@MainActivity, "Starting $nextLens camera stream...", Toast.LENGTH_SHORT).show()
                } else {
                    provider.switchLens(nextLens)
                    Toast.makeText(this@MainActivity, "Switching to $nextLens camera...", Toast.LENGTH_SHORT).show()
                }
            } else {
                Toast.makeText(this@MainActivity, "Camera service initializing...", Toast.LENGTH_SHORT).show()
            }
        }.apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.2f).apply {
                marginEnd = dp(8)
            }
        }
        camBtnRow.addView(btnFlipCamera)

        btnToggleStream = createModernButton(
            text = "▶ Start Stream",
            bgColor = "#20243A",
            textColor = "#8F98FF"
        ) {
            val provider = P2PDaemonService.activeCameraProvider
            if (provider != null) {
                if (provider.isStreaming()) {
                    provider.stopStream()
                    Toast.makeText(this@MainActivity, "Camera stream stopped", Toast.LENGTH_SHORT).show()
                } else {
                    provider.startStream(provider.getCurrentLens())
                    Toast.makeText(this@MainActivity, "Camera stream started", Toast.LENGTH_SHORT).show()
                }
            }
        }.apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 0.8f)
        }
        camBtnRow.addView(btnToggleStream)
        camControlCard.addView(camBtnRow)
        root.addView(camControlCard)

        // =====================================================================
        // Scope 2.8: Mac Now Playing Media Controls (In-App & Notification)
        // =====================================================================
        // WHAT IT DOES: Displays the currently playing audio/video from Mac and
        //               provides interactive Play/Pause, Next, and Previous controls.
        // HOW IT DOES IT: Binds to MediaNotificationHelper.onNowPlayingChanged and
        //                 calls P2PDaemonService.sendMediaCommand().
        // WHY IT DOES IT: User requested media control to appear inside the app
        //                 and on the notification panel whenever media is playing on Mac.
        // =====================================================================
        val mediaSectionHeader = createSectionHeader("MAC NOW PLAYING MEDIA CONTROLS")
        root.addView(mediaSectionHeader)

        val mediaCard = createCardContainer()

        val mediaHeaderRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, 0, dp(10))
        }

        val mediaCardTitle = TextView(this).apply {
            text = "🎵 Mac Media Player"
            textSize = 15f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.WHITE)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        mediaHeaderRow.addView(mediaCardTitle)

        mediaStatusBadge = TextView(this).apply {
            text = "○ STANDBY"
            textSize = 10f
            typeface = Typeface.DEFAULT_BOLD
            setPadding(dp(8), dp(3), dp(8), dp(3))
            background = createPillDrawable("#20243A", "#6F7593")
            setTextColor(Color.parseColor("#A6ACC4"))
        }
        mediaHeaderRow.addView(mediaStatusBadge)
        mediaCard.addView(mediaHeaderRow)

        // Track Display Box
        val trackBox = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(12), dp(12), dp(12))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#0B0D17"))
                cornerRadius = dp(10f)
                setStroke(dp(1), Color.parseColor("#20243A"))
            }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { bottomMargin = dp(14) }
        }

        mediaTitleText = TextView(this).apply {
            text = "No active media playing on Mac"
            textSize = 15f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.parseColor("#A6ACC4"))
            setPadding(0, 0, 0, dp(4))
        }
        trackBox.addView(mediaTitleText)

        mediaSubtitleText = TextView(this).apply {
            text = "Start audio or video on Mac (Spotify, YouTube, Apple Music) to control it here and in your notifications."
            textSize = 12f
            setTextColor(Color.parseColor("#6F7593"))
        }
        trackBox.addView(mediaSubtitleText)
        mediaCard.addView(trackBox)

        // Media Controls Button Row (Prev, Play/Pause, Next)
        val mediaButtonRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, dp(10))
        }

        btnMediaPrev = createModernButton(
            text = "⏮ Prev",
            bgColor = "#20243A",
            textColor = "#8F98FF"
        ) {
            P2PDaemonService.sendMediaCommand("PREV_TRACK")
            Toast.makeText(this@MainActivity, "Previous Track", Toast.LENGTH_SHORT).show()
        }.apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginEnd = dp(6)
            }
        }
        mediaButtonRow.addView(btnMediaPrev)

        btnMediaPlayPause = createModernButton(
            text = "⏯ Play / Pause",
            bgColor = "#8F98FF",
            textColor = "#FFFFFF"
        ) {
            P2PDaemonService.sendMediaCommand("TOGGLE_PLAY_PAUSE")
            val isPlaying = P2PDaemonService.activeMediaNotificationHelper?.currentData?.isPlaying ?: false
            Toast.makeText(this@MainActivity, if (isPlaying) "Pausing Mac..." else "Playing Mac...", Toast.LENGTH_SHORT).show()
        }.apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1.4f).apply {
                marginEnd = dp(6)
            }
        }
        mediaButtonRow.addView(btnMediaPlayPause)

        btnMediaNext = createModernButton(
            text = "Next ⏭",
            bgColor = "#20243A",
            textColor = "#8F98FF"
        ) {
            P2PDaemonService.sendMediaCommand("NEXT_TRACK")
            Toast.makeText(this@MainActivity, "Next Track", Toast.LENGTH_SHORT).show()
        }.apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        mediaButtonRow.addView(btnMediaNext)
        mediaCard.addView(mediaButtonRow)

        val mediaFooterDesc = TextView(this).apply {
            text = "💡 Controls any media on Mac (Apple Music, Spotify, YouTube, Podcasts, QuickTime). Media controls also appear live in your Android notification shade & lock screen."
            textSize = 11f
            setTextColor(Color.parseColor("#6F7593"))
            setLineSpacing(dp(2f), 1f)
        }
        mediaCard.addView(mediaFooterDesc)
        root.addView(mediaCard)

        // =====================================================================
        // Scope 3: Universal Clipboard Hub (Android ⇄ Mac)
        // =====================================================================
        // WHAT IT DOES: Provides full clipboard visibility, live synchronization,
        //               custom message dispatch to Mac (⌘V), and recent history.
        // HOW IT DOES IT: Hooks into ClipboardSyncHelper to read/write system clipboard,
        //                 display live clip previews, and transmit custom text frames.
        // WHY IT DOES IT: Fulfills user request for a rich clipboard interface matching Mac.
        // =====================================================================
        val clipSectionHeader = createSectionHeader("UNIVERSAL CLIPBOARD HUB")
        root.addView(clipSectionHeader)

        val clipCard = createCardContainer()

        val clipHeaderRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, 0, dp(8))
        }

        val clipTitle = TextView(this).apply {
            text = "📋 Real-Time Clipboard Sync"
            textSize = 15f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.WHITE)
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }
        clipHeaderRow.addView(clipTitle)

        val clipBadge = TextView(this).apply {
            text = "✓ LIVE SYNC"
            textSize = 10f
            typeface = Typeface.DEFAULT_BOLD
            setPadding(dp(8), dp(3), dp(8), dp(3))
            background = createPillDrawable("#123222", "#3DDC84")
            setTextColor(Color.parseColor("#3DDC84"))
        }
        clipHeaderRow.addView(clipBadge)
        clipCard.addView(clipHeaderRow)

        val clipDesc = TextView(this).apply {
            text = "Text copied on Mac with ⌘C appears here instantly.\nText copied on Android is ready to paste on Mac with ⌘V."
            textSize = 12f
            setTextColor(Color.parseColor("#A6ACC4"))
            setLineSpacing(dp(2f), 1f)
            setPadding(0, 0, 0, dp(12))
        }
        clipCard.addView(clipDesc)

        // Sub-section 1: Current Active Clip Display
        val currentClipLabel = TextView(this).apply {
            text = "CURRENT CLIPBOARD CONTENT"
            textSize = 10f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.parseColor("#6F7593"))
            letterSpacing = 0.05f
            setPadding(0, 0, 0, dp(4))
        }
        clipCard.addView(currentClipLabel)

        currentClipDisplay = TextView(this).apply {
            text = "No clipboard items synced yet. Copy text on Mac or type below."
            textSize = 12f
            typeface = Typeface.MONOSPACE
            setTextColor(Color.parseColor("#F3F4FA"))
            setPadding(dp(12), dp(10), dp(12), dp(10))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#0B0D17"))
                cornerRadius = dp(8f)
                setStroke(dp(1), Color.parseColor("#20243A"))
            }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { bottomMargin = dp(8) }
        }
        clipCard.addView(currentClipDisplay)

        val copyCurrentRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, 0, 0, dp(14))
        }

        val btnCopyCurrent = createModernButton(
            text = "📋 Copy to Phone Clipboard",
            bgColor = "#20243A",
            textColor = "#8F98FF"
        ) {
            val text = currentClipDisplay.text.toString()
            if (text.isNotBlank() && !text.startsWith("No clipboard items")) {
                val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("LinkMyMac", text))
                Toast.makeText(this@MainActivity, "Copied to phone clipboard!", Toast.LENGTH_SHORT).show()
            }
        }.apply {
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginEnd = dp(8)
            }
        }
        copyCurrentRow.addView(btnCopyCurrent)

        val autoSyncBadge = TextView(this).apply {
            text = "⚡ LIVE AUTO-SYNC"
            textSize = 10f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            setPadding(dp(12), dp(9), dp(12), dp(9))
            background = createPillDrawable("#123222", "#3DDC84")
            setTextColor(Color.parseColor("#3DDC84"))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
        }
        copyCurrentRow.addView(autoSyncBadge)
        clipCard.addView(copyCurrentRow)

        // Sub-section 2: Compose & Send Custom Text to Mac
        val composeLabel = TextView(this).apply {
            text = "SEND CUSTOM TEXT TO MAC"
            textSize = 10f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.parseColor("#6F7593"))
            letterSpacing = 0.05f
            setPadding(0, 0, 0, dp(4))
        }
        clipCard.addView(composeLabel)

        clipInputText = EditText(this).apply {
            hint = "Type text, link, or note to paste on Mac..."
            setHintTextColor(Color.parseColor("#3B4262"))
            setTextColor(Color.parseColor("#F3F4FA"))
            textSize = 13f
            setPadding(dp(12), dp(10), dp(12), dp(10))
            background = GradientDrawable().apply {
                setColor(Color.parseColor("#0B0D17"))
                cornerRadius = dp(8f)
                setStroke(dp(1), Color.parseColor("#262B42"))
            }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { bottomMargin = dp(8) }
        }
        clipCard.addView(clipInputText)

        val btnSendToMac = createModernButton(
            text = "🚀 Send to Mac Clipboard (⌘V)",
            bgColor = "#8F98FF",
            textColor = "#FFFFFF"
        ) {
            val text = clipInputText.text.toString().trim()
            if (text.isNotEmpty()) {
                val helper = P2PDaemonService.activeClipboardHelper
                if (helper != null) {
                    helper.sendCustomTextToMac(text)
                } else {
                    val cm = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
                    cm.setPrimaryClip(ClipData.newPlainText("LinkMyMac", text))
                }
                clipInputText.setText("")
                updateClipboardUi()
                Toast.makeText(this@MainActivity, "Sent to Mac! Press ⌘V on your Mac to paste.", Toast.LENGTH_LONG).show()
            } else {
                Toast.makeText(this@MainActivity, "Enter some text first", Toast.LENGTH_SHORT).show()
            }
        }.apply {
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { bottomMargin = dp(16) }
        }
        clipCard.addView(btnSendToMac)

        // Sub-section 3: Recent History Items
        val historyLabel = TextView(this).apply {
            text = "RECENT SYNCED ITEMS"
            textSize = 10f
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.parseColor("#6F7593"))
            letterSpacing = 0.05f
            setPadding(0, 0, 0, dp(6))
        }
        clipCard.addView(historyLabel)

        historyItemsLayout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        clipCard.addView(historyItemsLayout)

        root.addView(clipCard)

        // =====================================================================
        // Scope 4: Cryptographic QR Pairing Hub
        // =====================================================================
        // WHAT IT DOES: Displays high-contrast scannable QR pairing token.
        // HOW IT DOES IT: Encodes TLS fingerprint, nonce, IPs via ZXing QRCodeWriter.
        // WHY IT DOES IT: Enables 1-second out-of-band camera pairing with Mac client.
        // =====================================================================
        root.addView(createSectionHeader("FILE SHARING"))
        val filesCard = createCardContainer()
        filesCard.addView(TextView(this).apply {
            text = "Send files to your Mac's Downloads folder. Files from your Mac are saved to " +
                "Download/LinkMyMac. You can also use Share → LinkMyMac Companion in any app."
            textSize = 12f
            setTextColor(Color.parseColor("#A6ACC4"))
            setLineSpacing(dp(2f), 1f)
            setPadding(0, 0, 0, dp(10))
        })
        filesCard.addView(createModernButton("Send Files to Mac", "#8F98FF", "#FFFFFF") { pickFilesForMac() })
        root.addView(filesCard)


        scroll.addView(root)
        setContentView(scroll)

        // Initial setup
        updatePairingUi() // also renders the QR
        updateAllPermissionStates()
    }

    // =========================================================================
    // UI helpers in the LinkMyMac design language (Figma Android/* components)
    // =========================================================================

    private fun c(hex: String): Int = Color.parseColor(hex)

    private val mediumFace: Typeface get() = Typeface.create("sans-serif-medium", Typeface.NORMAL)

    private fun roundRect(fill: String, radiusDp: Float, stroke: String? = null) = GradientDrawable().apply {
        setColor(c(fill))
        cornerRadius = dp(radiusDp)
        if (stroke != null) setStroke(dp(1), c(stroke))
    }

    private fun lmText(text: String, sizeSp: Float, color: String, medium: Boolean = false) = TextView(this).apply {
        this.text = text
        textSize = sizeSp
        setTextColor(c(color))
        if (medium) typeface = mediumFace
    }

    private fun lmCard(radiusDp: Float = 24f, padH: Int = 16, padV: Int = 16) = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        background = roundRect(LM.SURFACE, radiusDp)
        setPadding(dp(padH), dp(padV), dp(padH), dp(padV))
    }

    private fun iconView(res: Int, sizeDp: Int, tint: String) = ImageView(this).apply {
        setImageResource(res)
        imageTintList = ColorStateList.valueOf(c(tint))
        layoutParams = LinearLayout.LayoutParams(dp(sizeDp), dp(sizeDp))
    }

    private fun iconTile(res: Int, tileDp: Int, iconDp: Int, bg: String, tint: String, radiusDp: Float) = FrameLayout(this).apply {
        background = roundRect(bg, radiusDp)
        layoutParams = LinearLayout.LayoutParams(dp(tileDp), dp(tileDp))
        addView(iconView(res, iconDp, tint).apply { layoutParams = FrameLayout.LayoutParams(dp(iconDp), dp(iconDp), Gravity.CENTER) })
    }

    /** The LinkMyMac mark: brand gradient squircle with the link glyph (Figma Brand/App icon). */
    private fun brandMark(sizeDp: Int) = FrameLayout(this).apply {
        background = GradientDrawable(GradientDrawable.Orientation.TL_BR, intArrayOf(c("#6673FF"), c("#8C5CF5"))).apply {
            cornerRadius = dp(sizeDp * 0.25f)
        }
        layoutParams = LinearLayout.LayoutParams(dp(sizeDp), dp(sizeDp))
        val glyph = (sizeDp * 0.56f).toInt()
        addView(iconView(R.drawable.ic_lm_link, glyph, "#FFFFFF").apply {
            layoutParams = FrameLayout.LayoutParams(dp(glyph), dp(glyph), Gravity.CENTER)
        })
    }

    /** Status pill (Figma Android/Status chip). */
    private fun lmChip() = TextView(this).apply {
        textSize = 12f
        typeface = mediumFace
        letterSpacing = 0.03f
        setPadding(dp(10), dp(6), dp(12), dp(6))
    }

    private fun setChip(view: TextView, text: String, tone: String) {
        val (bg, dot, fg) = when (tone) {
            "success" -> Triple(LM.SUCCESS_SOFT, LM.SUCCESS, LM.SUCCESS)
            "warning" -> Triple(LM.WARNING_SOFT, LM.WARNING, LM.WARNING)
            "neutral" -> Triple(LM.SURFACE_MUTED, LM.TEXT3, LM.TEXT2)
            else -> Triple(LM.BRAND_SOFT, LM.BRAND, LM.ON_BRAND_SOFT)
        }
        view.text = SpannableStringBuilder().append("●  ", ForegroundColorSpan(c(dot)), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE).append(text)
        view.setTextColor(c(fg))
        view.background = roundRect(bg, 999f)
    }

    /** Text button with an optional leading icon (Figma Android/Button, Text variant). */
    private fun lmTextButton(text: String, icon: Int?, color: String, onClick: () -> Unit) = LinearLayout(this).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(14), dp(10), dp(14), dp(10))
        isClickable = true
        background = RippleDrawable(ColorStateList.valueOf(c("#22FFFFFF")), null, roundRect("#FFFFFF", 22f))
        setOnClickListener { onClick() }
        if (icon != null) addView(iconView(icon, 18, color).apply { (layoutParams as LinearLayout.LayoutParams).marginEnd = dp(8) })
        addView(lmText(text, 14f, color, medium = true))
    }

    private fun matchWrap(top: Int = 0) =
        LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(top) }

    private fun wrap(top: Int = 0) =
        LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(top) }

    private fun createSectionHeader(title: String): TextView = TextView(this).apply {
        text = title.uppercase()
        textSize = 12f
        typeface = mediumFace
        letterSpacing = 0.07f
        setTextColor(c(LM.TEXT3))
        setPadding(dp(8), dp(20), dp(8), dp(8))
    }

    private fun createCardContainer(): LinearLayout = lmCard(24f, 16, 16).apply {
        layoutParams = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT
        ).apply { bottomMargin = dp(12) }
    }

    private fun createPillDrawable(bgColorHex: String, strokeColorHex: String): GradientDrawable {
        return GradientDrawable().apply {
            setColor(Color.parseColor(bgColorHex))
            cornerRadius = dp(999f)
            setStroke(dp(1), Color.parseColor(strokeColorHex))
        }
    }

    /** Pill button (Figma Android/Button): brand fill for the main action, tonal otherwise. */
    @Suppress("UNUSED_PARAMETER")
    private fun createModernButton(
        text: String,
        bgColor: String,
        textColor: String,
        onClick: () -> Unit
    ): Button {
        val (bg, fg) = when (bgColor.uppercase()) {
            LM.BRAND -> LM.BRAND to LM.ON_BRAND
            LM.DANGER_SOFT -> LM.DANGER_SOFT to LM.DANGER
            else -> LM.BRAND_SOFT to LM.ON_BRAND_SOFT
        }
        return Button(this).apply {
            this.text = text
            setTextColor(c(fg))
            textSize = 14f
            typeface = mediumFace
            isAllCaps = false
            minHeight = dp(44)
            minimumHeight = dp(44)
            stateListAnimator = null
            setPadding(dp(20), dp(10), dp(20), dp(10))
            background = RippleDrawable(ColorStateList.valueOf(c("#33FFFFFF")), roundRect(bg, 22f), null)
            setOnClickListener { onClick() }
        }
    }
}

/** LinkMyMac dark-mode tokens (Figma "LinkMyMac" variables, Dark mode). */
private object LM {
    const val CANVAS = "#0B0D17"
    const val SURFACE = "#171A2B"
    const val SURFACE_MUTED = "#20243A"
    const val BORDER = "#262B42"
    const val TEXT = "#F3F4FA"
    const val TEXT2 = "#A6ACC4"
    const val TEXT3 = "#6F7593"
    const val BRAND = "#8F98FF"
    const val ON_BRAND = "#0B0D17"
    const val BRAND_SOFT = "#232859"
    const val ON_BRAND_SOFT = "#C3C8FF"
    const val SUCCESS = "#3DDC84"
    const val SUCCESS_SOFT = "#123222"
    const val WARNING = "#F6B84B"
    const val WARNING_SOFT = "#3A2B0C"
    const val DANGER = "#FF6E76"
    const val DANGER_SOFT = "#3B1418"
}
