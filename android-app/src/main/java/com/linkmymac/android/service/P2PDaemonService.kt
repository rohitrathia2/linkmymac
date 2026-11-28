package com.linkmymac.android.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ComponentName
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.BatteryManager
import android.os.Build
import android.Manifest
import android.content.pm.PackageManager
import android.os.Environment
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.telephony.TelephonyManager
import android.provider.OpenableColumns
import android.util.Base64
import android.util.Log
import com.linkmymac.android.crypto.PairingManager
import com.linkmymac.android.ui.MirrorConsentActivity
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.FileInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean

/**
 * =============================================================================
 * P2PDaemonService: Core Android P2P Networking & IPC Hub
 * =============================================================================
 * WHAT IT DOES: Acts as the central networking and messaging daemon on Android.
 *               Runs as a persistent foreground service, advertises the device
 *               over mDNS / DNS-SD (`_linkmymac._tcp.`), listens for TCP client
 *               connections on port 8765 (over both Wi-Fi and USB ADB forwarding),
 *               manages client sessions, and multiplexes binary and JSON protocol frames.
 * HOW IT DOES IT:
 *   1. Displays an ongoing low-priority notification to satisfy Android foreground
 *      service requirements and avoid OS process termination.
 *   2. Starts a `ServerSocket` on port 8765 dispatched on an asynchronous cached
 *      thread pool.
 *   3. Registers an mDNS service instance via Android `NsdManager`.
 *   4. Spawns a dedicated `ClientSession` runnable for each accepted TCP socket,
 *      decoding the 8-byte binary frame header (`MAGIC_HEADER: 0x4C4D`, flags, length).
 *   5. Dispatches framed messages to clipboard, notification, media, and heartbeat
 *      subsystems.
 * WHY IT DOES IT: Provides a resilient, battery-efficient local transport layer that
 *                 bridges Android and macOS without third-party cloud intermediaries.
 * =============================================================================
 */
class P2PDaemonService : Service() {

    companion object {
        const val SERVICE_TYPE = "_linkmymac._tcp."
        const val SERVICE_NAME = "LinkMyMac-Android"
        const val DEFAULT_PORT = 8765
        private const val MAGIC_HEADER: Short = 0x4C4D // "LM"
        private const val FLAG_JSON_FRAME: Short = 0x0001
        private const val TAG = "P2PDaemonService"
        private const val MAX_SESSIONS = 8 // caps threads an unauthenticated flood can pin
        private const val PRE_AUTH_TIMEOUT_MS = 30_000
        private const val FILE_CHUNK_BYTES = 64 * 1024
        private const val RANGE_CHUNK_BYTES = 256 * 1024
        private const val FILES_CHANNEL_ID = "linkmymac_files"
        private const val PROMPTS_CHANNEL_ID = "linkmymac_prompts"
        private const val HOTSPOT_PROMPT_ID = 3002

        @Volatile
        var instance: P2PDaemonService? = null
            private set

        /** Name of the most recently authenticated Mac, for "Connected to …" in the app. */
        @Volatile
        var connectedMacName: String? = null

        val activeCameraProvider: CameraStreamProvider?
            get() = instance?.cameraProvider

        val activeClipboardHelper: ClipboardSyncHelper?
            get() = instance?.clipboardHelper

        val activeMediaNotificationHelper: MediaNotificationHelper?
            get() = instance?.mediaNotificationHelper

        /** Mac output volume 0–100 from VOLUME_STATE; -1 until the Mac reports it. */
        @Volatile var macVolume = -1
        @Volatile var macMuted = false
        /** Called on the socket thread when the Mac's volume or mute changes. */
        @Volatile var onMacVolumeChanged: (() -> Unit)? = null

        /** Thread-safe list of active connected Mac client sessions */
        private val activeClients = CopyOnWriteArrayList<ClientSession>()

        /** Paired Macs only: a socket that hasn't passed the handshake isn't "connected". */
        val connectedClientCount: Int
            get() = activeClients.count { it.authenticated }

        val isMacConnected: Boolean
            get() = connectedClientCount > 0

        /** Callback invoked on the main thread whenever a Mac connects or disconnects */
        @Volatile
        var onClientCountChanged: ((Int) -> Unit)? = null

        /**
         * ---------------------------------------------------------------------
         * broadcastControlFrame: Outbound Multiplexed Event Broadcaster
         * ---------------------------------------------------------------------
         * WHAT IT DOES: Broadcasts a JSON control or notification frame to all
         *               currently connected macOS clients.
         * HOW IT DOES IT: Encodes `json` to UTF-8 bytes and iterates `activeClients`,
         *                 invoking `session.sendFrame(FLAG_JSON_FRAME, payloadBytes)`.
         * WHY IT DOES IT: Subsystems (e.g. notifications, clipboard) can emit updates
         *                 without holding direct socket references.
         * ---------------------------------------------------------------------
         */
        fun broadcastControlFrame(json: JSONObject) {
            val payloadBytes = json.toString().toByteArray(Charsets.UTF_8)
            // Every subsystem routes through here, so this one check keeps notifications,
            // clipboard, camera frames etc. away from sockets that haven't paired.
            activeClients.forEach { session ->
                if (session.authenticated) session.sendFrame(FLAG_JSON_FRAME, payloadBytes)
            }
        }

        /** The Mac that asked for screen mirroring; frames go only to it. */
        @Volatile
        private var mirrorViewer: ClientSession? = null

        /**
         * Blocking send of a screen frame to the Mac that asked for mirroring (paces the encoder
         * to the link). False once that Mac is gone, which stops mirroring: the screen never
         * falls through to another paired Mac.
         */
        fun sendToMacBlocking(json: JSONObject): Boolean {
            val viewer = mirrorViewer?.takeIf { it.authenticated && it in activeClients } ?: return false
            return viewer.sendNow(json)
        }

        /** After the person grants SMS / phone permissions in the app. */
        fun onPermissionsChanged() {
            instance?.startPhoneBridges()
        }

        /** After "Forget paired Macs": drop live sessions so they must pair again. */
        fun disconnectAllClients() {
            activeClients.forEach { it.close() }
        }

        /**
         * Sends content URIs (share sheet / file picker) to the paired Mac.
         * Streams are opened right here, while the caller's URI grant is still valid,
         * then copied on a background thread. Returns false if no paired Mac is connected.
         */
        fun sendFilesToMac(uris: List<Uri>): Boolean {
            val service = instance ?: return false
            // ponytail: first paired Mac only; add a target picker if people pair several.
            val session = activeClients.firstOrNull { it.authenticated } ?: return false
            val files = uris.mapNotNull { service.openForSending(it) }
            if (files.isEmpty()) return false
            service.ioExecutor.execute {
                files.forEach { session.streamFile(UUID.randomUUID().toString(), it) }
            }
            return true
        }

        /**
         * ---------------------------------------------------------------------
         * sendMediaCommand: Outbound Mac Media Playback Command Dispatcher
         * ---------------------------------------------------------------------
         * WHAT IT DOES: Emits media playback control commands to Mac.
         * HOW IT DOES IT: Dispatches {"type":"MEDIA_CONTROL_COMMAND","action":action}.
         * WHY IT DOES IT: Triggered by notification buttons and in-app media controls.
         * ---------------------------------------------------------------------
         */
        fun sendMediaCommand(action: String) {
            val cmd = JSONObject().apply {
                put("type", "MEDIA_CONTROL_COMMAND")
                put("action", action)
            }
            broadcastControlFrame(cmd)
        }
    }

    private val running = AtomicBoolean(false)
    private val ioExecutor = Executors.newCachedThreadPool()
    // Gallery downloads queue one at a time, so "Save 200 to Mac" doesn't open 200 streams at once.
    private val mediaDownloadExecutor = Executors.newSingleThreadExecutor()
    private var serverSocket: ServerSocket? = null
    private var nsdManager: NsdManager? = null
    private var registrationListener: NsdManager.RegistrationListener? = null

    private lateinit var clipboardHelper: ClipboardSyncHelper
    private lateinit var mediaProvider: MediaStoreProvider
    private lateinit var cameraProvider: CameraStreamProvider
    private lateinit var mediaNotificationHelper: MediaNotificationHelper
    private lateinit var smsBridge: SmsBridge
    private lateinit var callBridge: CallBridge
    private val mainHandler = Handler(Looper.getMainLooper())

    /**
     * -------------------------------------------------------------------------
     * onCreate: Service Lifecycle Bootstrap
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Initializes helpers, mounts foreground notification, and spins
     *               up the TCP server and mDNS registration.
     * HOW IT DOES IT: Instantiates `ClipboardSyncHelper` and `MediaStoreProvider`,
     *                 calls `startForegroundDaemonNotification()`, starts clipboard
     *                 monitoring, and calls `startSocketServer()` and `registerMdnsService()`.
     * WHY IT DOES IT: Guarantees that whenever the service is alive, all subsystems
     *                 are ready to accept connections and process payloads.
     * -------------------------------------------------------------------------
     */
    override fun onCreate() {
        super.onCreate()
        instance = this
        clipboardHelper = ClipboardSyncHelper(this)
        mediaProvider = MediaStoreProvider(this)
        cameraProvider = CameraStreamProvider(this)
        mediaNotificationHelper = MediaNotificationHelper(this)
        smsBridge = SmsBridge(this)
        callBridge = CallBridge(this) { smsBridge.contactName(it) }
        startPhoneBridges()

        startForegroundDaemonNotification()
        clipboardHelper.startMonitoring()
        mediaProvider.startObserving {
            Log.d("P2PDaemonService", "MediaStore changed dynamically, notifying connected Macs")
            val event = JSONObject().apply {
                put("type", "MEDIA_GALLERY_UPDATED")
            }
            broadcastControlFrame(event)
        }
        startSocketServer(DEFAULT_PORT)
        registerMdnsService(DEFAULT_PORT)
    }

    /**
     * -------------------------------------------------------------------------
     * onStartCommand: Sticky Service Re-Start Policy
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Returns `START_STICKY` to instruct the OS to restart the service
     *               if killed under low memory pressure.
     * HOW IT DOES IT: Returns the `START_STICKY` integer constant to Android framework.
     * WHY IT DOES IT: Ensures continuous availability of the companion bridge.
     * -------------------------------------------------------------------------
     */
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    /**
     * -------------------------------------------------------------------------
     * onDestroy: Graceful Service Teardown & Resource Cleanup
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Stops monitoring, tears down mDNS, closes server and client
     *               sockets, and shuts down executor threads.
     * HOW IT DOES IT: Sets `running = false`, halts clipboard listeners, calls
     *                 `unregisterMdnsService()`, closes `serverSocket`, closes all
     *                 `activeClients`, and invokes `ioExecutor.shutdownNow()`.
     * WHY IT DOES IT: Releases network ports and prevents resource leaks when the
     *                 user closes or uninstalls the application.
     * -------------------------------------------------------------------------
     */
    override fun onDestroy() {
        instance = null
        running.set(false)
        clipboardHelper.stopMonitoring()
        mediaProvider.stopObserving()
        cameraProvider.stopStream()
        mediaNotificationHelper.teardown()
        smsBridge.stopObserving()
        callBridge.stop()
        ScreenMirrorService.stop(this)
        unregisterMdnsService()
        try { serverSocket?.close() } catch (_: Exception) {}
        activeClients.forEach { it.close() }
        activeClients.clear()
        onClientCountChanged?.invoke(0)
        ioExecutor.shutdownNow()
        mediaDownloadExecutor.shutdownNow()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * -------------------------------------------------------------------------
     * startForegroundDaemonNotification: Foreground Service Notification Setup
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Creates a persistent, low-priority status notification.
     * HOW IT DOES IT: Creates a `NotificationChannel` with `IMPORTANCE_LOW` and calls
     *                 `startForeground(1001, notification)`.
     * WHY IT DOES IT: Mandated by modern Android OS to run persistent background
     *                 services without being killed by the Android Doze mechanism.
     * -------------------------------------------------------------------------
     */
    private fun startForegroundDaemonNotification() {
        val channelId = "linkmymac_daemon_channel"
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            channelId,
            "LinkMyMac Background Connection",
            NotificationManager.IMPORTANCE_LOW
        )
        nm.createNotificationChannel(channel)

        val notification = Notification.Builder(this, channelId)
            .setContentTitle("LinkMyMac Active")
            .setContentText("Listening for paired Mac on port $DEFAULT_PORT")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    1001,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(1001, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            } else {
                startForeground(1001, notification)
            }
        } catch (_: Exception) {
            try {
                startForeground(1001, notification)
            } catch (_: Exception) {}
        }
    }

    /**
     * -------------------------------------------------------------------------
     * startSocketServer: TCP Server Socket Loop
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Binds a TCP ServerSocket to port 8765 and accepts incoming connections.
     * HOW IT DOES IT:
     *   1. Atomically sets `running` to true.
     *   2. Creates `ServerSocket(port)` on a background thread.
     *   3. Enters accept loop: when a Mac connects, configures `tcpNoDelay = true`
     *      to minimize latency, wraps the socket in a `ClientSession`, adds it to
     *      `activeClients`, and schedules it on `ioExecutor`.
     * WHY IT DOES IT: Enables high-performance duplex streaming over local Wi-Fi and
     *                 ADB USB port forwarding (`adb forward tcp:8765 tcp:8765`).
     * -------------------------------------------------------------------------
     */
    private fun startSocketServer(port: Int) {
        if (!running.compareAndSet(false, true)) return

        ioExecutor.execute {
            try {
                serverSocket = ServerSocket(port)
                while (running.get()) {
                    val clientSocket = serverSocket?.accept() ?: break
                    if (activeClients.size >= MAX_SESSIONS) {
                        clientSocket.close()
                        continue
                    }
                    clientSocket.tcpNoDelay = true
                    clientSocket.soTimeout = PRE_AUTH_TIMEOUT_MS // cleared once the Mac authenticates
                    val session = ClientSession(clientSocket)
                    activeClients.add(session)
                    ioExecutor.execute(session)
                }
            } catch (_: Exception) {
                running.set(false)
            }
        }
    }

    /**
     * -------------------------------------------------------------------------
     * registerMdnsService: Zero-Config Local DNS-SD Broadcaster
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Advertises the LinkMyMac service on the local Wi-Fi subnet.
     * HOW IT DOES IT: Configures `NsdServiceInfo` with service type `_linkmymac._tcp.`
     *                 and registers it with Android's `NsdManager`.
     * WHY IT DOES IT: Allows the macOS app to discover the phone automatically using
     *                 Bonjour (`NWBrowser`) without entering manual IP addresses.
     * -------------------------------------------------------------------------
     */
    private fun registerMdnsService(port: Int) {
        val serviceInfo = NsdServiceInfo().apply {
            serviceName = "$SERVICE_NAME-${Build.MODEL}"
            serviceType = SERVICE_TYPE
            setPort(port)
        }

        nsdManager = (getSystemService(Context.NSD_SERVICE) as NsdManager).apply {
            registrationListener = object : NsdManager.RegistrationListener {
                override fun onServiceRegistered(info: NsdServiceInfo?) {}
                override fun onRegistrationFailed(info: NsdServiceInfo?, errorCode: Int) {}
                override fun onServiceUnregistered(info: NsdServiceInfo?) {}
                override fun onUnregistrationFailed(info: NsdServiceInfo?, errorCode: Int) {}
            }
            registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registrationListener)
        }
    }

    /**
     * -------------------------------------------------------------------------
     * unregisterMdnsService: mDNS Advertisement Teardown
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Unregisters the DNS-SD advertisement from the local network.
     * HOW IT DOES IT: Invokes `nsdManager.unregisterService(registrationListener)`.
     * WHY IT DOES IT: Cleans up Bonjour discovery entries when the daemon shuts down.
     * -------------------------------------------------------------------------
     */
    private fun unregisterMdnsService() {
        try {
            registrationListener?.let { nsdManager?.unregisterService(it) }
        } catch (_: Exception) {}
    }

    /**
     * =========================================================================
     * ClientSession: Per-Connection Framed Protocol Handler
     * =========================================================================
     * WHAT IT DOES: Manages the bidirectional frame read/write lifecycle for an
     *               individual connected macOS client.
     * HOW IT DOES IT: Reads 8-byte framing headers, decodes payload bodies,
     *                 routes JSON commands to specific subsystems, and serializes
     *                 synchronized outbound response frames.
     * WHY IT DOES IT: Isolates each connected client's I/O and state, ensuring one
     *                 slow or dropping client does not block the entire service.
     * =========================================================================
     */
    inner class ClientSession(private val socket: Socket) : Runnable {
        private val input = DataInputStream(socket.getInputStream())
        private val output = DataOutputStream(socket.getOutputStream())
        private val writeLock = Any()
        private val sendExecutor = Executors.newSingleThreadExecutor()

        /** Set once the Mac proves it is paired; until then every other frame is dropped. */
        @Volatile
        var authenticated = false
            private set
        private val nonce = PairingManager.newNonce()
        private var macDeviceId = ""

        /** Files being received from the Mac. Touched only by this session's read thread. */
        private val incomingFiles = HashMap<String, IncomingFile>()

        /** Video byte ranges the Mac no longer needs (seek, or player closed). */
        private val cancelledRanges = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

        /**
         * ---------------------------------------------------------------------
         * run: Inbound Stream Parsing Loop
         * ---------------------------------------------------------------------
         * WHAT IT DOES: Sequentially reads and processes wire frames from the Mac.
         * HOW IT DOES IT:
         *   1. Reads 2-byte magic header; verifies equality to `0x4C4D` ("LM").
         *   2. Reads 2-byte flags field and 4-byte payload length integer.
         *   3. Validates length bounds (1 byte to 16 MB).
         *   4. Reads exact payload byte array via `input.readFully()`.
         *   5. Dispatches to `handleIncomingFrame()`.
         * WHY IT DOES IT: Guarantees framing integrity and detects corrupted or
         *                 misaligned streams immediately.
         * ---------------------------------------------------------------------
         */
        override fun run() {
            try {
                sendJson(JSONObject()
                    .put("type", "AUTH_CHALLENGE")
                    .put("phoneId", PairingManager.phoneId(this@P2PDaemonService))
                    .put("phoneName", "${Build.MANUFACTURER} ${Build.MODEL}")
                    .put("nonce", nonce))
                while (running.get() && !socket.isClosed) {
                    val magic = input.readShort()
                    if (magic != MAGIC_HEADER) {
                        throw IllegalStateException("Invalid frame magic header: $magic")
                    }
                    val flags = input.readShort()
                    val length = input.readInt()
                    if (length <= 0 || length > 16 * 1024 * 1024) {
                        throw IllegalStateException("Invalid frame payload length: $length")
                    }

                    val payload = ByteArray(length)
                    input.readFully(payload)
                    handleIncomingFrame(flags, payload)
                }
            } catch (e: Exception) {
                Log.e("P2PDaemonService", "ClientSession exception in read loop", e)
            } finally {
                close()
                incomingFiles.keys.toList().forEach { discardIncoming(it, "Connection lost", notifyMac = false) }
                activeClients.remove(this)
                onClientCountChanged?.invoke(connectedClientCount)
                if (connectedClientCount == 0) {
                    cameraProvider.stopStream()
                    ScreenMirrorService.stop(this@P2PDaemonService) // nobody left to watch
                    macVolume = -1
                    onMacVolumeChanged?.invoke()
                    mediaNotificationHelper.updateNowPlaying(
                        hasMedia = false,
                        title = "",
                        artist = "",
                        album = "",
                        isPlaying = false,
                        duration = 0.0,
                        elapsedTime = 0.0,
                        appName = "",
                        artwork = ""
                    )
                }
            }
        }

        /**
         * ---------------------------------------------------------------------
         * handleIncomingFrame: Protocol Message Router
         * ---------------------------------------------------------------------
         * WHAT IT DOES: Parses incoming JSON control messages and executes actions.
         * HOW IT DOES IT: Inspects `type` field in JSON:
         *   - `PAIRING_HANDSHAKE`: Replies with `PAIRING_ACK` and triggers notification sync.
         *   - `NOTIFICATIONS_SYNC_REQUEST`: Synchronizes currently posted notifications.
         *   - `HEARTBEAT_PING`: Replies with `HEARTBEAT_PONG`, timestamps, and battery capacity.
         *   - `NOTIFICATION_ACTION`: Dispatches quick replies or dismissals.
         *   - `CLIPBOARD_EVENT`: Applies remote Mac clipboard text to Android.
         *   - `MEDIA_INDEX_REQUEST`: Queries MediaStore photos and returns index metadata.
         *   - `MEDIA_DOWNLOAD_REQUEST`: Streams photo file in 64 KB chunks.
         * WHY IT DOES IT: Acts as the command dispatcher linking desktop requests
         *                 with Android system features.
         * ---------------------------------------------------------------------
         */
        private fun handleIncomingFrame(flags: Short, payload: ByteArray) {
            if (flags != FLAG_JSON_FRAME) return
            val json = JSONObject(String(payload, Charsets.UTF_8))
            val frameType = json.optString("type")
            Log.d("P2PDaemonService", "handleIncomingFrame: type=$frameType")

            // Until the Mac proves it's paired, the handshake is the only frame we act on.
            if (!authenticated) {
                if (frameType == "PAIRING_HANDSHAKE") handlePairingHandshake(json)
                return
            }

            when (frameType) {
                // SMS (reads run off the socket thread: big inboxes take a moment)
                "SMS_THREADS_REQUEST" -> ioExecutor.execute { startPhoneBridges(); sendJson(smsBridge.threads(json.optInt("limit", 60))) }
                "SMS_MESSAGES_REQUEST" -> ioExecutor.execute {
                    sendJson(smsBridge.messages(json.optLong("threadId"), json.optInt("limit", 200)))
                }
                "SMS_SEND" -> {
                    val error = smsBridge.send(json.optString("address"), json.optString("body"))
                    sendJson(JSONObject()
                        .put("type", "SMS_SEND_RESULT")
                        .put("requestId", json.optString("requestId"))
                        .put("ok", error == null)
                        .apply { error?.let { put("error", it) } })
                }

                // Calls (audio stays on the phone)
                "CALL_ACTION" -> sendCallResult(callBridge.act(json.optString("action")))
                "CALL_DIAL" -> sendCallResult(callBridge.dial(json.optString("number")))
                "CALL_LOG_REQUEST" -> ioExecutor.execute { startPhoneBridges(); sendJson(callBridge.recent(json.optInt("limit", 100))) }

                // Screen mirroring + mouse/keyboard control
                "MIRROR_START" -> {
                    mirrorViewer = this
                    requestMirroring()
                }
                "MIRROR_STOP" -> ScreenMirrorService.stop(this@P2PDaemonService)
                "INPUT_TAP", "INPUT_SWIPE", "INPUT_TEXT", "INPUT_KEY", "INPUT_GLOBAL" -> {
                    val control = ControlService.instance
                    if (control == null) {
                        sendJson(JSONObject().put("type", "CONTROL_STATUS").put("enabled", false))
                    } else {
                        mainHandler.post { control.handle(json) }
                    }
                }

                // Hotspot: apps can't switch tethering on, so ask the person with one tap
                "HOTSPOT_REQUEST" -> {
                    promptHotspot()
                    sendJson(JSONObject().put("type", "HOTSPOT_RESULT").put("prompted", true))
                }

                // A paired Mac removes only itself (vs. "Forget Paired Macs", which drops all)
                "UNPAIR" -> {
                    PairingManager.forgetMac(this@P2PDaemonService, macDeviceId)
                    close()
                }

                // Video streaming: the Mac's player asks for byte ranges as it needs them
                "MEDIA_RANGE_REQUEST" -> {
                    val requestId = json.optString("requestId")
                    val uri = mediaProvider.contentUriFor(json.optLong("mediaId"))
                    val offset = json.optLong("offset")
                    val length = json.optLong("length")
                    ioExecutor.execute { streamRange(requestId, uri, offset, length) }
                }
                "MEDIA_RANGE_CANCEL" -> cancelledRanges.add(json.optString("requestId"))

                // Mac → phone file sharing (saved to Download/LinkMyMac)
                "FILE_OFFER" -> beginIncoming(json)
                "FILE_CHUNK" -> appendIncoming(json)
                "FILE_TRANSFER_COMPLETE" -> finishIncoming(json)

                // Explicit manual or reconnect notification sync request
                "NOTIFICATIONS_SYNC_REQUEST" -> {
                    LMMNotificationListener.instance?.syncActiveNotifications()
                }

                // Heartbeat ping & real-time battery telemetry query
                "HEARTBEAT_PING" -> {
                    val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
                    val batteryPct = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
                    val pong = JSONObject().apply {
                        put("type", "HEARTBEAT_PONG")
                        put("clientTimeMs", json.optLong("clientTimeMs"))
                        put("serverTimeMs", System.currentTimeMillis())
                        put("batteryPercent", batteryPct)
                        val (network, signal) = cellularInfo()
                        put("network", network)
                        put("signalLevel", signal)
                    }
                    sendFrame(FLAG_JSON_FRAME, pong.toString().toByteArray(Charsets.UTF_8))
                }

                // Remote notification action or inline text reply
                "NOTIFICATION_ACTION" -> {
                    val key = json.optString("notificationKey")
                    val actionId = json.optString("actionId")
                    val replyText = json.optString("inlineReplyText", "")
                    val dismissOnly = json.optBoolean("dismissOnly", false)
                    LMMNotificationListener.instance?.executeNotificationAction(
                        key, actionId, replyText.ifEmpty { null }, dismissOnly
                    )
                }

                // Inbound clipboard synchronization from macOS
                "CLIPBOARD_EVENT" -> {
                    val text = json.optString("textValue")
                    val sha = json.optString("contentSha256")
                    clipboardHelper.applyIncomingClipFromMac(text, sha)
                }

                // Dismiss all active notifications from Android status bar
                "NOTIFICATION_CLEAR_ALL" -> {
                    val listener = LMMNotificationListener.instance
                    Log.d("P2PDaemonService", "NOTIFICATION_CLEAR_ALL received! listener=$listener")
                    if (listener != null) {
                        listener.clearAllNotifications()
                    } else {
                        try {
                            android.service.notification.NotificationListenerService.requestRebind(
                                ComponentName(this@P2PDaemonService, LMMNotificationListener::class.java)
                            )
                        } catch (_: Exception) {}
                    }
                }

                // Dismiss a specific notification by its key
                "NOTIFICATION_DISMISS" -> {
                    val key = json.optString("key")
                    if (key.isNotEmpty()) {
                        LMMNotificationListener.instance?.dismissNotification(key)
                    }
                }

                // Camera roll gallery metadata pagination query
                "MEDIA_INDEX_REQUEST" -> {
                    val offset = json.optInt("offset", 0)
                    val limit = json.optInt("limit", 30)
                    val includeThumbs = json.optBoolean("includeThumbnails", true)
                    val response = mediaProvider.queryMediaIndex(offset, limit, includeThumbs, json.optString("mediaType"))
                    sendFrame(FLAG_JSON_FRAME, response.toString().toByteArray(Charsets.UTF_8))
                }

                // Remote media item deletion request
                "MEDIA_DELETE_REQUEST" -> {
                    val mediaId = json.optLong("mediaId")
                    val success = mediaProvider.deleteMediaItem(mediaId)
                    val response = JSONObject().apply {
                        put("type", "MEDIA_DELETE_RESPONSE")
                        put("mediaId", mediaId.toString())
                        put("success", success)
                    }
                    sendFrame(FLAG_JSON_FRAME, response.toString().toByteArray(Charsets.UTF_8))
                }

                // Full-resolution original photo download request
                "MEDIA_DOWNLOAD_REQUEST" -> {
                    val mediaId = json.optLong("mediaId")
                    val transferId = json.optString("transferId")
                    openForSending(mediaProvider.contentUriFor(mediaId))?.let { file ->
                        // Keep the Mac's media_<id>.<ext> naming so it recognises earlier downloads.
                        val named = file.copy(name = "$transferId.${file.name.substringAfterLast('.', "jpg")}")
                        mediaDownloadExecutor.execute { streamFile(transferId, named) }
                    }
                }

                // Live Continuity Camera stream control & lens switching
                "CAMERA_CONTROL" -> {
                    val action = json.optString("action", "START")
                    val lens = json.optString("lens", "BACK")
                    when (action) {
                        "START" -> cameraProvider.startStream(lens)
                        "STOP" -> cameraProvider.stopStream()
                        "SWITCH_LENS" -> cameraProvider.switchLens(lens)
                    }
                }

                // Mac Now Playing active media playback & controls sync
                "NOW_PLAYING_UPDATE" -> {
                    val hasMedia = json.optBoolean("hasMedia", false)
                    val title = json.optString("title", "")
                    val artist = json.optString("artist", "")
                    val album = json.optString("album", "")
                    val isPlaying = json.optBoolean("isPlaying", false)
                    val duration = json.optDouble("duration", 0.0)
                    val elapsedTime = json.optDouble("elapsedTime", 0.0)
                    val appName = json.optString("appName", "Mac Media")
                    val artwork = json.optString("artwork", "")
                    mediaNotificationHelper.updateNowPlaying(
                        hasMedia = hasMedia,
                        title = title,
                        artist = artist,
                        album = album,
                        isPlaying = isPlaying,
                        duration = duration,
                        elapsedTime = elapsedTime,
                        appName = appName,
                        artwork = artwork
                    )
                }

                "VOLUME_STATE" -> {
                    macVolume = json.optInt("volume", 0).coerceIn(0, 100)
                    macMuted = json.optBoolean("muted", false)
                    onMacVolumeChanged?.invoke()
                }
            }
        }

        /**
         * ---------------------------------------------------------------------
         * sendFrame: Wire-Level Binary Framing & Dispatcher
         * ---------------------------------------------------------------------
         * WHAT IT DOES: Serializes and sends an 8-byte header followed by the payload.
         * HOW IT DOES IT: Synchronizes on `writeLock`, packs an 8-byte buffer
         *                 (`MAGIC_HEADER: 0x4C4D`, flags, payload length), writes
         *                 the header and payload, and calls `output.flush()`.
         * WHY IT DOES IT: Thread-safe locking ensures concurrent broadcasts do not
         *                 interleave byte streams on the underlying TCP socket.
         * ---------------------------------------------------------------------
         */
        fun sendFrame(flags: Short, payload: ByteArray) {
            try {
                sendExecutor.execute {
                    try {
                        writeFrame(flags, payload)
                    } catch (e: Exception) {
                        Log.e(TAG, "sendFrame failed, closing session: ${e.message}")
                        close()
                    }
                }
            } catch (_: RejectedExecutionException) {
                // Session already closed; its read loop is tearing it down.
            }
        }

        private fun writeFrame(flags: Short, payload: ByteArray) {
            synchronized(writeLock) {
                val header = ByteBuffer.allocate(8)
                    .putShort(MAGIC_HEADER)
                    .putShort(flags)
                    .putInt(payload.size)
                    .array()
                output.write(header)
                output.write(payload)
                output.flush()
            }
        }

        private fun sendJson(json: JSONObject) =
            sendFrame(FLAG_JSON_FRAME, json.toString().toByteArray(Charsets.UTF_8))

        /** Blocking send for bulk streams: TCP backpressure paces the reader, nothing queues up in RAM. */
        private fun sendJsonNow(json: JSONObject) {
            try {
                writeFrame(FLAG_JSON_FRAME, json.toString().toByteArray(Charsets.UTF_8))
            } catch (e: Exception) {
                close()
                throw e
            }
        }

        /** Blocking send for other components (screen frames). False if the link is gone. */
        fun sendNow(json: JSONObject): Boolean = try {
            sendJsonNow(json)
            true
        } catch (_: Exception) {
            false
        }

        private fun sendCallResult(error: String?) {
            sendJson(JSONObject()
                .put("type", "CALL_ACTION_RESULT")
                .put("ok", error == null)
                .apply { error?.let { put("error", it) } })
        }

        private fun handlePairingHandshake(json: JSONObject) {
            val result = PairingManager.authenticate(
                this@P2PDaemonService,
                deviceId = json.optString("deviceId"),
                nonce = nonce,
                proof = json.optString("proof"),
                code = json.optString("pairingCode"),
                macPublicKey = json.optString("macPublicKey")
            )
            val ack = JSONObject()
                .put("type", "PAIRING_ACK")
                .put("deviceName", "${Build.MANUFACTURER} ${Build.MODEL}")
            when (result) {
                is PairingManager.Result.Rejected -> {
                    sendJson(ack.put("accepted", false).put("error", result.reason))
                    return
                }
                is PairingManager.Result.Accepted -> {
                    // Prove we hold the same secret, so the Mac knows this is the real phone.
                    ack.put("accepted", true)
                        .put("proof", PairingManager.proof(result.secret, "phone", json.optString("macNonce")))
                    result.phonePublicKey?.let { ack.put("phonePublicKey", it) }
                }
            }
            sendJson(ack) // queued before any broadcast can reach this session
            authenticated = true
            macDeviceId = json.optString("deviceId")
            socket.soTimeout = 0
            Log.i(TAG, "Mac \"${json.optString("deviceName")}\" authenticated")
            connectedMacName = json.optString("deviceName").ifBlank { null }
            onClientCountChanged?.invoke(connectedClientCount)
            LMMNotificationListener.instance?.syncActiveNotifications()
        }

        /** Phone → Mac: FILE_OFFER, 64 KB FILE_CHUNKs, FILE_TRANSFER_COMPLETE. */
        fun streamFile(transferId: String, file: OutgoingFile) {
            try {
                file.input.use { input ->
                    sendJsonNow(JSONObject()
                        .put("type", "FILE_OFFER")
                        .put("transferId", transferId)
                        .put("fileName", file.name)
                        .put("mimeType", file.mime)
                        .put("totalBytes", file.size))
                    val buffer = ByteArray(FILE_CHUNK_BYTES)
                    var index = 0
                    while (true) {
                        val n = input.readChunk(buffer)
                        if (n == 0) break
                        sendJsonNow(JSONObject()
                            .put("type", "FILE_CHUNK")
                            .put("transferId", transferId)
                            .put("chunkIndex", index++)
                            .put("dataBase64", Base64.encodeToString(buffer, 0, n, Base64.NO_WRAP)))
                        if (n < buffer.size) break
                    }
                    sendJsonNow(JSONObject()
                        .put("type", "FILE_TRANSFER_COMPLETE")
                        .put("transferId", transferId)
                        .put("totalChunks", index))
                }
            } catch (e: Exception) {
                Log.w(TAG, "File transfer $transferId failed: ${e.message}")
            }
        }

        /**
         * Sends [length] bytes from [offset] as MEDIA_RANGE_DATA frames, then MEDIA_RANGE_DONE.
         * Blocking writes pace it to the link; a MEDIA_RANGE_CANCEL stops it between chunks.
         */
        private fun streamRange(requestId: String, uri: Uri, offset: Long, length: Long) {
            var error: String? = null
            try {
                contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                    FileInputStream(pfd.fileDescriptor).use { input ->
                        input.channel.position(offset)
                        val buffer = ByteArray(RANGE_CHUNK_BYTES)
                        var position = offset
                        var remaining = length
                        while (remaining > 0 && requestId !in cancelledRanges) {
                            val n = input.read(buffer, 0, minOf(buffer.size.toLong(), remaining).toInt())
                            if (n < 0) break
                            sendJsonNow(JSONObject()
                                .put("type", "MEDIA_RANGE_DATA")
                                .put("requestId", requestId)
                                .put("offset", position)
                                .put("dataBase64", Base64.encodeToString(buffer, 0, n, Base64.NO_WRAP)))
                            position += n
                            remaining -= n
                        }
                    }
                } ?: run { error = "Media not found" }
            } catch (e: Exception) {
                error = e.message ?: "Read failed"
            } finally {
                cancelledRanges.remove(requestId)
                sendJson(JSONObject()
                    .put("type", "MEDIA_RANGE_DONE")
                    .put("requestId", requestId)
                    .apply { error?.let { put("error", it) } })
            }
        }

        // Mac → phone: written straight into a pending MediaStore Downloads row.
        private fun beginIncoming(json: JSONObject) {
            val id = json.optString("transferId")
            if (id.isEmpty() || incomingFiles.containsKey(id)) return
            val name = safeFileName(json.optString("fileName"))
            val mime = json.optString("mimeType").ifBlank { "application/octet-stream" }
            val values = ContentValues().apply {
                put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                put(MediaStore.MediaColumns.MIME_TYPE, mime)
                put(MediaStore.MediaColumns.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/LinkMyMac")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
            val uri = try {
                contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            } catch (_: Exception) {
                null
            }
            val out = uri?.let { try { contentResolver.openOutputStream(it) } catch (_: Exception) { null } }
            if (uri == null || out == null) {
                uri?.let { contentResolver.delete(it, null, null) }
                sendJson(transferResult(id, ok = false, error = "Phone could not create the file"))
                return
            }
            incomingFiles[id] = IncomingFile(uri, out, name, mime)
        }

        private fun appendIncoming(json: JSONObject) {
            val id = json.optString("transferId")
            val file = incomingFiles[id] ?: return
            try {
                check(json.optInt("chunkIndex", -1) == file.nextChunk) { "Chunk out of order" }
                file.out.write(Base64.decode(json.optString("dataBase64"), Base64.NO_WRAP))
                file.nextChunk++
            } catch (e: Exception) {
                discardIncoming(id, e.message ?: "Write failed", notifyMac = true)
            }
        }

        private fun finishIncoming(json: JSONObject) {
            val id = json.optString("transferId")
            val file = incomingFiles[id] ?: return
            try {
                check(json.optInt("totalChunks", -1) == file.nextChunk) { "Missing chunks" }
                file.out.close()
                contentResolver.update(file.uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
                incomingFiles.remove(id)
                sendJson(transferResult(id, ok = true, error = null))
                notifyFileReceived(file)
            } catch (e: Exception) {
                discardIncoming(id, e.message ?: "Save failed", notifyMac = true)
            }
        }

        private fun discardIncoming(id: String, reason: String, notifyMac: Boolean) {
            val file = incomingFiles.remove(id) ?: return
            try { file.out.close() } catch (_: Exception) {}
            try { contentResolver.delete(file.uri, null, null) } catch (_: Exception) {}
            if (notifyMac) sendJson(transferResult(id, ok = false, error = reason))
        }

        /**
         * ---------------------------------------------------------------------
         * close: Client Socket Termination
         * ---------------------------------------------------------------------
         * WHAT IT DOES: Closes the underlying client socket.
         * HOW IT DOES IT: Calls `socket.close()`, safely catching IOExceptions.
         * WHY IT DOES IT: Releases operating system socket file descriptors.
         * ---------------------------------------------------------------------
         */
        fun close() {
            try { sendExecutor.shutdownNow() } catch (_: Exception) {}
            try { socket.close() } catch (_: Exception) {}
        }
    }

    // =========================================================================
    // Phone features: SMS, calls, mirroring prompt, hotspot prompt
    // =========================================================================

    /**
     * Starts the SMS observer and call listener; each is a no-op until its permission is granted.
     * Callers include socket threads, so hop to the main thread: one place, no double registration.
     */
    fun startPhoneBridges() {
        mainHandler.post {
            smsBridge.startObserving { broadcastControlFrame(JSONObject().put("type", "SMS_UPDATED")) }
            callBridge.start { broadcastControlFrame(it) }
        }
    }

    /**
     * Android always asks the person before screen capture. Open the prompt directly when
     * allowed (app visible, or Mac Control on), and also offer it as a notification.
     */
    private fun requestMirroring() {
        if (ScreenMirrorService.isRunning) return
        val consent = Intent(this, MirrorConsentActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try { startActivity(consent) } catch (_: Exception) {}
        postPrompt(ScreenMirrorService.PROMPT_NOTIFICATION_ID, "Mirror your screen to your Mac?", "Tap to allow",
            PendingIntent.getActivity(this, 1, consent, PendingIntent.FLAG_IMMUTABLE))
    }

    private fun promptHotspot() {
        val tether = Intent(Intent.ACTION_MAIN)
            .setClassName("com.android.settings", "com.android.settings.TetherSettings")
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val target = if (tether.resolveActivity(packageManager) != null) tether
            else Intent(Settings.ACTION_WIRELESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        postPrompt(HOTSPOT_PROMPT_ID, "Your Mac wants your hotspot", "Tap to open hotspot settings",
            PendingIntent.getActivity(this, 2, target, PendingIntent.FLAG_IMMUTABLE))
    }

    private fun postPrompt(id: Int, title: String, text: String, tap: PendingIntent) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(PROMPTS_CHANNEL_ID, "Requests from your Mac", NotificationManager.IMPORTANCE_HIGH)
        )
        nm.notify(id, Notification.Builder(this, PROMPTS_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(tap)
            .setAutoCancel(true)
            .build())
    }

    /** "5G" / "4G" / … (needs phone permission) and signal bars 0–4 (-1 unknown). */
    private fun cellularInfo(): Pair<String, Int> {
        val telephony = getSystemService(TelephonyManager::class.java) ?: return "" to -1
        val type = if (checkSelfPermission(Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED) {
            when (telephony.dataNetworkType) {
                TelephonyManager.NETWORK_TYPE_NR -> "5G"
                TelephonyManager.NETWORK_TYPE_LTE -> "4G"
                TelephonyManager.NETWORK_TYPE_UNKNOWN -> ""
                TelephonyManager.NETWORK_TYPE_HSPAP, TelephonyManager.NETWORK_TYPE_HSPA,
                TelephonyManager.NETWORK_TYPE_HSDPA, TelephonyManager.NETWORK_TYPE_HSUPA,
                TelephonyManager.NETWORK_TYPE_UMTS -> "3G"
                else -> "2G"
            }
        } else ""
        val signal = try { telephony.signalStrength?.level ?: -1 } catch (_: Exception) { -1 }
        return type to signal
    }

    // =========================================================================
    // File sharing helpers
    // =========================================================================

    data class OutgoingFile(val name: String, val mime: String, val size: Long, val input: InputStream)

    private class IncomingFile(val uri: Uri, val out: OutputStream, val name: String, val mime: String) {
        var nextChunk = 0
    }

    /** Opens a content URI for streaming, with its display name and size (size -1 if unknown). */
    private fun openForSending(uri: Uri): OutgoingFile? = try {
        var name = uri.lastPathSegment ?: "file"
        var size = -1L
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val nameIdx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIdx = c.getColumnIndex(OpenableColumns.SIZE)
                if (nameIdx >= 0) c.getString(nameIdx)?.let { name = it }
                if (sizeIdx >= 0 && !c.isNull(sizeIdx)) size = c.getLong(sizeIdx)
            }
        }
        contentResolver.openInputStream(uri)?.let { input ->
            OutgoingFile(name, contentResolver.getType(uri) ?: "application/octet-stream", size, input)
        }
    } catch (e: Exception) {
        Log.w(TAG, "Cannot open $uri for sending: ${e.message}")
        null
    }

    private fun transferResult(id: String, ok: Boolean, error: String?): JSONObject = JSONObject()
        .put("type", "FILE_TRANSFER_RESULT")
        .put("transferId", id)
        .put("ok", ok)
        .apply { error?.let { put("error", it) } }

    /** The name comes from the network: keep only a plain file name. */
    private fun safeFileName(raw: String): String =
        raw.substringAfterLast('/').substringAfterLast('\\')
            .filter { it >= ' ' }
            .trim().trimStart('.')
            .take(200)
            .ifEmpty { "file" }

    private fun notifyFileReceived(file: IncomingFile) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(FILES_CHANNEL_ID, "Files from Mac", NotificationManager.IMPORTANCE_DEFAULT)
        )
        val notificationId = 10_000 + (ContentUris.parseId(file.uri) % 1_000_000).toInt()
        val view = Intent(Intent.ACTION_VIEW)
            .setDataAndType(file.uri, file.mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        val tap = PendingIntent.getActivity(
            this, notificationId, view, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        nm.notify(notificationId, Notification.Builder(this, FILES_CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("Received from Mac")
            .setContentText("${file.name} • saved to Download/LinkMyMac")
            .setContentIntent(tap)
            .setAutoCancel(true)
            .build())
    }
}

/** Fills [buffer] unless the stream ends first; returns the byte count (0 at EOF). */
private fun InputStream.readChunk(buffer: ByteArray): Int {
    var filled = 0
    while (filled < buffer.size) {
        val n = read(buffer, filled, buffer.size - filled)
        if (n < 0) break
        filled += n
    }
    return filled
}
