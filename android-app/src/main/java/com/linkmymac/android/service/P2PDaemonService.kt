package com.linkmymac.android.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.BatteryManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import org.json.JSONObject
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
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

        @Volatile
        var instance: P2PDaemonService? = null
            private set

        val activeCameraProvider: CameraStreamProvider?
            get() = instance?.cameraProvider

        val activeClipboardHelper: ClipboardSyncHelper?
            get() = instance?.clipboardHelper

        val activeMediaNotificationHelper: MediaNotificationHelper?
            get() = instance?.mediaNotificationHelper

        /** Thread-safe list of active connected Mac client sessions */
        private val activeClients = CopyOnWriteArrayList<ClientSession>()

        val connectedClientCount: Int
            get() = activeClients.size

        val isMacConnected: Boolean
            get() = activeClients.isNotEmpty()

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
            activeClients.forEach { session ->
                session.sendFrame(FLAG_JSON_FRAME, payloadBytes)
            }
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
    private var serverSocket: ServerSocket? = null
    private var nsdManager: NsdManager? = null
    private var registrationListener: NsdManager.RegistrationListener? = null

    private lateinit var clipboardHelper: ClipboardSyncHelper
    private lateinit var mediaProvider: MediaStoreProvider
    private lateinit var cameraProvider: CameraStreamProvider
    private lateinit var mediaNotificationHelper: MediaNotificationHelper

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
        unregisterMdnsService()
        try { serverSocket?.close() } catch (_: Exception) {}
        activeClients.forEach { it.close() }
        activeClients.clear()
        onClientCountChanged?.invoke(0)
        ioExecutor.shutdownNow()
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
                    clientSocket.tcpNoDelay = true
                    val session = ClientSession(clientSocket)
                    activeClients.add(session)
                    val count = activeClients.size
                    onClientCountChanged?.invoke(count)
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
                activeClients.remove(this)
                val count = activeClients.size
                onClientCountChanged?.invoke(count)
                if (activeClients.isEmpty()) {
                    cameraProvider.stopStream()
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

            when (frameType) {
                // Handshake acknowledgment & instant notification priming
                "PAIRING_HANDSHAKE" -> {
                    val ack = JSONObject().apply {
                        put("type", "PAIRING_ACK")
                        put("accepted", true)
                        put("deviceName", "${Build.MANUFACTURER} ${Build.MODEL}")
                    }
                    sendFrame(FLAG_JSON_FRAME, ack.toString().toByteArray(Charsets.UTF_8))
                    LMMNotificationListener.instance?.syncActiveNotifications()
                }

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
                    val response = mediaProvider.queryMediaIndex(offset, limit, includeThumbs)
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
                    mediaProvider.streamMediaFileInChunks(mediaId, transferId) { chunkJson ->
                        sendFrame(FLAG_JSON_FRAME, chunkJson.toString().toByteArray(Charsets.UTF_8))
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
                    mediaNotificationHelper.updateNowPlaying(
                        hasMedia = hasMedia,
                        title = title,
                        artist = artist,
                        album = album,
                        isPlaying = isPlaying,
                        duration = duration,
                        elapsedTime = elapsedTime,
                        appName = appName
                    )
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
            sendExecutor.execute {
                synchronized(writeLock) {
                    try {
                        val header = ByteBuffer.allocate(8)
                            .putShort(MAGIC_HEADER)
                            .putShort(flags)
                            .putInt(payload.size)
                            .array()
                        output.write(header)
                        output.write(payload)
                        output.flush()
                    } catch (e: Exception) {
                        Log.e("P2PDaemonService", "sendFrame failed, closing session: ${e.message}")
                        close()
                    }
                }
            }
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
}
