import Foundation
import Network
import CryptoKit
import Combine
import AppKit
import CoreImage
import ImageIO

/**
 * =============================================================================
 * Core Data Models & Transport Entities
 * =============================================================================
 */

/**
 * -----------------------------------------------------------------------------
 * DiscoveredPeer: Local Bonjour / DNS-SD Device Reference
 * -----------------------------------------------------------------------------
 * WHAT IT DOES: Represents an Android companion device discovered on the LAN.
 * HOW IT DOES IT: Encapsulates service identifier, human-readable name, and the
 *                 opaque Network.framework `NWEndpoint`.
 * WHY IT DOES IT: Decouples network discovery representation from active TCP
 *                 socket instances, allowing UI lists to render discovered peers.
 * -----------------------------------------------------------------------------
 */
public struct DiscoveredPeer: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let endpoint: NWEndpoint
}

/**
 * -----------------------------------------------------------------------------
 * MirroredNotification: Intercepted Remote Android Notification Model
 * -----------------------------------------------------------------------------
 * WHAT IT DOES: Stores notification payload mirrored from the Android phone.
 * HOW IT DOES IT: Holds metadata (package, title, body, timestamp) and interactive
 *                 quick-reply actions parsed from incoming JSON frames.
 * WHY IT DOES IT: Powers the desktop notification feed and native macOS
 *                 `UNUserNotificationCenter` banner alerts.
 * -----------------------------------------------------------------------------
 */
public struct MirroredNotification: Identifiable, Sendable {
    public let id: String // Unique Android StatusBarNotification key
    public let appName: String
    public let packageName: String
    public let title: String
    public let body: String
    public let postTimeMs: Int64
    public let appIconData: Data?
    public let actions: [NotificationActionOption]
}

/**
 * -----------------------------------------------------------------------------
 * NotificationActionOption: Interactive RemoteInput Action Model
 * -----------------------------------------------------------------------------
 * WHAT IT DOES: Represents an inline reply or quick action button attached to a notification.
 * HOW IT DOES IT: Contains `actionId`, label text, and `supportsInlineReply` flag.
 * WHY IT DOES IT: Enables macOS users to type replies to Android messaging apps
 *                 (WhatsApp, SMS, Slack) directly from their computer.
 * -----------------------------------------------------------------------------
 */
public struct NotificationActionOption: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let supportsInlineReply: Bool
    public let replyPlaceholder: String
}

/**
 * -----------------------------------------------------------------------------
 * RemoteMediaItem: Android Camera Roll Photo & Thumbnail Model
 * -----------------------------------------------------------------------------
 * WHAT IT DOES: Represents an individual photo in the phone's MediaStore gallery.
 * HOW IT DOES IT: Caches dimensions, modified epoch, file size, and 200x200
 *                 WebP-compressed thumbnail binary bytes.
 * WHY IT DOES IT: Allows high-speed gallery browsing without downloading heavy
 *                 multi-megabyte full-resolution files until explicitly requested.
 * -----------------------------------------------------------------------------
 */
public struct RemoteMediaItem: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let mimeType: String
    public let sizeBytes: Int64
    public let width: Int
    public let height: Int
    public let thumbnailData: Data?
}

/**
 * =============================================================================
 * MacP2PClient: Core Networking & Protocol Engine
 * =============================================================================
 * WHAT IT DOES:
 *   Manages the complete network lifecycle between macOS and Android:
 *     - Bonjour DNS-SD peer discovery (`_linkmymac._tcp`)
 *     - Direct TCP connection establishment over LAN or USB loopback
 *     - Automatic reconnect resilience on connection drops
 *     - 8-byte length-delimited wire framing and defragmentation
 *     - Multiplexed dispatching of notifications, clipboard, and file chunks
 *
 * HOW IT DOES IT:
 *   - Uses Apple's modern Network.framework (`NWBrowser`, `NWConnection`).
 *   - Enforces big-endian 8-byte framing: `[0x4C4D ("LM")][Flags: 2B][Length: 4B]`.
 *   - Runs entirely on `@MainActor` to provide thread-safe `@Published` UI bindings.
 *   - Buffers fragmented TCP packet chunks and extracts completed frames.
 *
 * WHY IT DOES IT:
 *   Raw TCP streams offer no native message boundary delimitation. Without custom
 *   framing and defragmentation, JSON packets larger than the MTU (~1500 bytes)
 *   or multi-chunk file transfers will corrupt and fail JSON deserialization.
 * =============================================================================
 */
@MainActor
public final class MacP2PClient: ObservableObject {

    public static let shared = MacP2PClient()

    public static let serviceType = "_linkmymac._tcp"
    private static let magicBytes: UInt16 = 0x4C4D // "LM"
    private static let flagJsonFrame: UInt16 = 0x0001

    // Reactive State Bindings for SwiftUI
    @Published public private(set) var discoveredPeers: [DiscoveredPeer] = []
    @Published public private(set) var connectionState: String = "Disconnected"
    @Published public private(set) var connectedDeviceName: String? = nil
    @Published public private(set) var isWirelessConnection: Bool = false
    @Published public private(set) var remoteBatteryPercent: Int? = nil
    @Published public private(set) var notifications: [MirroredNotification] = []
    @Published public private(set) var mediaItems: [RemoteMediaItem] = []
    @Published public private(set) var totalMediaCount: Int? = nil
    @Published public private(set) var isSyncingAllMedia: Bool = false
    @Published public private(set) var downloadedMediaFiles: [String: URL] = [:]

    // Live Continuity Camera & Lens Controls
    @Published public private(set) var latestCameraFrame: NSImage? = nil
    @Published public private(set) var isCameraStreaming: Bool = false
    @Published public private(set) var currentCameraLens: String = "BACK" // "BACK" or "FRONT"
    @Published public private(set) var cameraRotationDegrees: Int = 0
    @Published public private(set) var isCameraSwitching: Bool = false
    @Published public private(set) var cameraErrorMessage: String? = nil

    // Universal Clipboard Sync State & History
    @Published public private(set) var lastSyncedClipboardText: String = ""
    @Published public private(set) var clipboardSyncHistory: [String] = []

    // Network Engine Components
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var heartbeatTimer: Timer?
    private var autoReconnectTimer: Timer?
    private var lastDirectHost: String? = "127.0.0.1"
    private var lastDirectPort: UInt16? = 8765
    private var receiveBuffer = Data()

    // File Download Assembler: transferId -> Accumulating byte buffer
    private var incomingTransfers: [String: Data] = [:]
    private let networkQueue = DispatchQueue(label: "com.linkmymac.network", qos: .userInitiated)

    // Subsystem Callbacks
    public var onRemoteClipboardReceived: ((String, String) -> Void)?
    public var onMirroredNotificationPosted: ((MirroredNotification) -> Void)?
    public var onMediaControlCommandReceived: ((String) -> Void)?
    public var onConnected: (() -> Void)?

    public init() {
        startDiscovery()
        // Connect directly via local Wi-Fi IP address
        connectDirect(host: "192.168.1.8", port: 8765)
    }

    // =========================================================================
    // MARK: - 1. Bonjour / mDNS Discovery
    // =========================================================================

    /**
     * WHAT IT DOES:
     *   Scans the local area network (LAN) for advertising Android companion devices.
     *
     * HOW IT DOES IT:
     *   - Creates an `NWBrowser` querying the `_linkmymac._tcp` service type.
     *   - Sets `params.includePeerToPeer = true` to search Wi-Fi and AWDL interfaces.
     *   - Maps incoming browse results to `DiscoveredPeer` instances and updates
     *     the `@Published discoveredPeers` array on `@MainActor`.
     *
     * WHY IT DOES IT:
     *   Zero-configuration networking (mDNS / DNS-SD) allows users to connect
     *   over local Wi-Fi without manually memorizing or typing dynamic IP addresses.
     */
    public func startDiscovery() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: nil)
        let params = NWParameters()
        params.includePeerToPeer = true

        let nwBrowser = NWBrowser(for: descriptor, using: params)
        nwBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                self.discoveredPeers = results.compactMap { result in
                    if case let .service(name, _, _, _) = result.endpoint {
                        return DiscoveredPeer(id: name, name: name, endpoint: result.endpoint)
                    }
                    return nil
                }

                // If not currently connected over USB or Wi-Fi, automatically connect to discovered peer
                if self.connectedDeviceName == nil, let first = self.discoveredPeers.first {
                    print("[MacP2PClient] Discovered active wireless peer over mDNS: \(first.name). Auto-connecting...")
                    self.connect(to: first)
                }
            }
        }
        nwBrowser.start(queue: .main)
        self.browser = nwBrowser
        self.connectionState = "Searching LAN (_linkmymac._tcp)..."
    }

    /**
     * WHAT IT DOES: Cancels active LAN Bonjour browsing.
     * HOW IT DOES IT: Calls `cancel()` on the `NWBrowser` instance and nils the reference.
     * WHY IT DOES IT: Frees socket handles and reduces radio power consumption when idle.
     */
    public func stopDiscovery() {
        browser?.cancel()
        browser = nil
    }

    // =========================================================================
    // MARK: - 2. Connection Lifecycle & Auto-Reconnect Resilience
    // =========================================================================

    /**
     * WHAT IT DOES: Initiates a connection to a Bonjour-discovered peer.
     * HOW IT DOES IT: Wraps the peer's `NWEndpoint` in an `NWConnection` using TCP.
     * WHY IT DOES IT: Enables 1-tap connection from the discovered peers sidebar list.
     */
    public func connect(to peer: DiscoveredPeer) {
        isWirelessConnection = true
        let params = NWParameters.tcp
        params.serviceClass = .responsiveData
        let conn = NWConnection(to: peer.endpoint, using: params)
        establishConnection(conn, displayLabel: peer.name)
    }

    /**
     * WHAT IT DOES:
     *   Connects directly to an explicit IP address and port (e.g. `127.0.0.1:8765`).
     *
     * HOW IT DOES IT:
     *   - Records `lastDirectHost` and `lastDirectPort` for automatic reconnects.
     *   - Instantiates `NWConnection` targeting `NWEndpoint.Host` and `NWEndpoint.Port`.
     *   - Configures TCP with `.responsiveData` QoS service class for low latency.
     *
     * WHY IT DOES IT:
     *   Required for USB ADB loopback tunneling (`adb forward tcp:8765 tcp:8765`)
     *   and corporate networks where multicast mDNS packets are dropped by routers.
     */
    public func connectDirect(host: String, port: UInt16, pinnedCertFingerprint: String? = nil) {
        lastDirectHost = host
        lastDirectPort = port
        isWirelessConnection = (host != "127.0.0.1" && host != "localhost")
        let nwHost = NWEndpoint.Host(host)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let params = NWParameters.tcp
        params.serviceClass = .responsiveData
        let conn = NWConnection(host: nwHost, port: nwPort, using: params)
        establishConnection(conn, displayLabel: "\(host):\(port)")
    }

    /**
     * WHAT IT DOES:
     *   Schedules an automatic reconnection attempt if an active connection drops.
     *
     * HOW IT DOES IT:
     *   - Ensures only one timer is active (`autoReconnectTimer == nil`).
     *   - If a Bonjour wireless peer has been discovered, prioritizes connecting wirelessly.
     *   - Falls back to `lastDirectHost` / `lastDirectPort`.
     *
     * WHY IT DOES IT:
     *   Seamlessly transitions from USB to Wi-Fi when the user unplugs the cable,
     *   mirroring Apple Continuity's effortless wireless handoff.
     */
    private func scheduleAutoReconnect() {
        guard autoReconnectTimer == nil else { return }
        autoReconnectTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.autoReconnectTimer = nil
                if let peer = self.discoveredPeers.first {
                    print("[MacP2PClient] Auto-connecting to wireless peer \(peer.name)...")
                    self.connect(to: peer)
                } else if let host = self.lastDirectHost, let port = self.lastDirectPort {
                    self.connectDirect(host: host, port: port)
                }
            }
        }
    }

    /**
     * WHAT IT DOES:
     *   Attaches state update listeners, opens the socket, and initiates the handshake.
     *
     * HOW IT DOES IT:
     *   - Binds `stateUpdateHandler` to observe `.ready`, `.failed`, `.waiting`, `.cancelled`.
     *   - On `.ready`: invalidates reconnect timer, sends `PAIRING_HANDSHAKE`, starts
     *     heartbeat ping loop, begins receiving chunks, requests notification sync, and
     *     requests the initial 30 camera roll thumbnails.
     *   - On `.failed`/`.waiting`: logs error and schedules `scheduleAutoReconnect()`.
     *
     * WHY IT DOES IT:
     *   Centralizes socket event transition handling and ensures immediate data hydration
     *   the instant the transport layer becomes ready.
     */
    private func establishConnection(_ conn: NWConnection, displayLabel: String) {
        disconnect(clearReconnect: false)
        self.connection = conn
        self.connectionState = "Connecting to \(displayLabel)..."

        conn.stateUpdateHandler = { [weak self] state in
            print("[MacP2PClient] Socket state changed: \(state)")
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.autoReconnectTimer?.invalidate()
                    self.autoReconnectTimer = nil
                    self.connectionState = "Connected"
                    self.connectedDeviceName = displayLabel
                    self.sendPairingHandshake()
                    self.startHeartbeatLoop()
                    self.receiveNextChunk()
                    self.requestNotificationSync()
                    self.requestMediaIndex(offset: 0, limit: 30)
                    self.onConnected?()
                case .failed(let error):
                    self.connectionState = "Connecting (auto-retry): \(error.localizedDescription)"
                    self.connectedDeviceName = nil
                    self.scheduleAutoReconnect()
                case .waiting(let error):
                    self.connectionState = "Waiting: \(error.localizedDescription)"
                    self.scheduleAutoReconnect()
                case .cancelled:
                    self.connectionState = "Disconnected"
                    self.connectedDeviceName = nil
                default:
                    break
                }
            }
        }

        conn.start(queue: networkQueue)
    }

    /**
     * WHAT IT DOES: Tears down the active TCP connection and clears buffers.
     * HOW IT DOES IT: Cancels timers, cancels NWConnection, purges receiveBuffer.
     * WHY IT DOES IT: Ensures clean socket release and prevents stale state leakage.
     */
    public func disconnect(clearReconnect: Bool = false) {
        if clearReconnect {
            lastDirectHost = nil
            lastDirectPort = nil
            autoReconnectTimer?.invalidate()
            autoReconnectTimer = nil
        }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
        connectedDeviceName = nil
        connectionState = "Disconnected"
    }

    // =========================================================================
    // MARK: - 3. Wire Framing Engine (8-Byte Header Serialization & Parsing)
    // =========================================================================

    /**
     * WHAT IT DOES:
     *   Prefixes an outbound dictionary payload with an 8-byte framing header
     *   and transmits it over the TCP socket.
     *
     * HOW IT DOES IT:
     *   - Encodes JSON dictionary to raw UTF-8 bytes using `JSONSerialization`.
     *   - Constructs an 8-byte big-endian header:
     *       * [0..1]: Magic Bytes `0x4C4D` ("LM")
     *       * [2..3]: Flags `0x0001` (JSON Control Frame)
     *       * [4..7]: 32-bit big-endian unsigned payload length
     *   - Concatenates header + payload and transmits via `conn.send()`.
     *
     * WHY IT DOES IT:
     *   TCP is a continuous stream without message boundaries. The 8-byte header
     *   allows the Android socket server to know the exact length of the message
     *   before deserializing, preventing buffer truncation and framing desync.
     */
    @discardableResult
    public func sendControlJSON(_ dict: [String: Any]) -> Bool {
        guard let conn = connection,
              connectionState == "Connected",
              let payload = try? JSONSerialization.data(withJSONObject: dict, options: []) else {
            return false
        }

        var header = Data(capacity: 8)
        var magic = Self.magicBytes.bigEndian
        var flags = Self.flagJsonFrame.bigEndian
        var length = UInt32(payload.count).bigEndian

        header.append(Data(bytes: &magic, count: 2))
        header.append(Data(bytes: &flags, count: 2))
        header.append(Data(bytes: &length, count: 4))

        var frame = header
        frame.append(payload)

        conn.send(content: frame, completion: .contentProcessed { _ in })
        return true
    }

    /**
     * WHAT IT DOES:
     *   Continuously pulls inbound TCP byte chunks from Network.framework into
     *   the persistent receive buffer.
     *
     * HOW IT DOES IT:
     *   - Calls `conn.receive(minimumIncompleteLength: 1, maximumLength: 65536)`.
     *   - Appends received bytes to `receiveBuffer`.
     *   - Calls `processReceiveBuffer()` to extract complete frames.
     *   - Automatically schedules the next receive read or handles disconnection.
     *
     * WHY IT DOES IT:
     *   Network packets arrive in non-deterministic chunk sizes (MTU fragmentation).
     *   Accumulating chunks in an internal buffer is necessary to reassemble
     *   multi-chunk frames (like 300KB media index responses).
     */
    private func receiveNextChunk() {
        guard let conn = connection else { return }

        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.receiveBuffer.append(data)
                    self.processReceiveBuffer()
                }
                if isComplete || error != nil {
                    self.disconnect()
                    self.scheduleAutoReconnect()
                } else {
                    self.receiveNextChunk()
                }
            }
        }
    }

    /**
     * WHAT IT DOES:
     *   Parses and defragments complete 8-byte framed packets out of `receiveBuffer`.
     *
     * HOW IT DOES IT:
     *   - Checks if `receiveBuffer.count >= 8`.
     *   - Validates magic header `0x4C4D` using big-endian byte loading.
     *   - Reads 32-bit payload length.
     *   - Verifies if full payload has arrived (`receiveBuffer.count >= 8 + length`).
     *   - Slices payload subrange, removes processed bytes from buffer, and passes
     *     payload to `handleIncomingJSONPayload()`.
     *
     * WHY IT DOES IT:
     *   Guarantees that JSON deserialization is only performed on 100% complete
     *   messages, preventing syntax parsing crashes.
     */
    private func processReceiveBuffer() {
        while receiveBuffer.count >= 8 {
            let magic = receiveBuffer.subdata(in: 0..<2).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            guard magic == Self.magicBytes else {
                // Invalid framing stream; disconnect cleanly
                disconnect()
                return
            }

            let flags = receiveBuffer.subdata(in: 2..<4).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            let length = Int(receiveBuffer.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })

            guard receiveBuffer.count >= 8 + length else {
                // Wait for remaining bytes of this frame to arrive
                return
            }

            let payload = receiveBuffer.subdata(in: 8..<(8 + length))
            receiveBuffer.removeSubrange(0..<(8 + length))

            if flags == Self.flagJsonFrame {
                handleIncomingJSONPayload(payload)
            }
        }
    }

    // =========================================================================
    // MARK: - 4. Frame Dispatching & Protocol Handlers
    // =========================================================================

    /**
     * WHAT IT DOES:
     *   Routes deserialized JSON frames to their respective subsystem handlers.
     *
     * HOW IT DOES IT:
     *   Switches on the `"type"` field:
     *     - `PAIRING_ACK`: Updates `connectedDeviceName`.
     *     - `HEARTBEAT_PONG`: Updates `remoteBatteryPercent`.
     *     - `NOTIFICATION_EVENT`: Updates mirrored notification list.
     *     - `CLIPBOARD_EVENT`: Dispatches remote text to local clipboard bridge.
     *     - `MEDIA_INDEX_RESPONSE`: Parses photo metadata & WebP thumbnails.
     *     - `FILE_CHUNK`: Appends incoming chunk data to transfer buffer.
     *     - `FILE_TRANSFER_COMPLETE`: Writes fully assembled file to disk.
     *
     * WHY IT DOES IT:
     *   Acts as the central multiplexing hub, converting wire-level frames into
     *   actionable domain state for UI and local system services.
     */
    private func handleIncomingJSONPayload(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "PAIRING_ACK":
            if let deviceName = json["deviceName"] as? String {
                self.connectedDeviceName = deviceName
            }
            self.onConnected?()

        case "HEARTBEAT_PONG":
            if let pct = json["batteryPercent"] as? Int {
                self.remoteBatteryPercent = pct
            }

        case "NOTIFICATION_EVENT":
            handleNotificationFrame(json)

        case "CLIPBOARD_EVENT":
            if let text = json["textValue"] as? String,
               let sha = json["contentSha256"] as? String {
                self.lastSyncedClipboardText = text
                if !self.clipboardSyncHistory.contains(text) {
                    self.clipboardSyncHistory.insert(text, at: 0)
                    if self.clipboardSyncHistory.count > 25 {
                        self.clipboardSyncHistory.removeLast()
                    }
                }
                onRemoteClipboardReceived?(text, sha)
            }

        case "MEDIA_CONTROL_COMMAND":
            if let action = json["action"] as? String {
                onMediaControlCommandReceived?(action)
            }

        case "CAMERA_FRAME":
            let rotation = json["rotationDegrees"] as? Int ?? 0
            self.cameraRotationDegrees = rotation
            if let lens = json["lens"] as? String {
                self.currentCameraLens = lens
            }
            if let b64 = json["frameBase64"] as? String,
               let imgData = Data(base64Encoded: b64) {
                if let oriented = Self.orientedImage(from: imgData, fallbackRotation: rotation) {
                    self.latestCameraFrame = oriented
                } else if let img = NSImage(data: imgData) {
                    self.latestCameraFrame = img
                }
                self.isCameraStreaming = true
                self.isCameraSwitching = false
                self.cameraErrorMessage = nil
            }

        case "CAMERA_STREAM_STATUS":
            if let streaming = json["isStreaming"] as? Bool {
                self.isCameraStreaming = streaming
            }
            if let lens = json["lens"] as? String {
                self.currentCameraLens = lens
            }
            if let switching = json["isSwitching"] as? Bool {
                self.isCameraSwitching = switching
            } else if !(json["isStreaming"] as? Bool ?? true) {
                self.isCameraSwitching = false
            }
            if let err = json["error"] as? String {
                self.cameraErrorMessage = err
            } else if !(json["isSwitching"] as? Bool ?? false) {
                self.cameraErrorMessage = nil
            }

        case "MEDIA_INDEX_RESPONSE":
            handleMediaIndexResponse(json)

        case "MEDIA_GALLERY_UPDATED":
            print("[MacP2PClient] Android media gallery changed dynamically. Auto-refreshing media index...")
            requestMediaIndex(offset: 0, limit: 30)

        case "MEDIA_DELETE_RESPONSE":
            if let mediaId = json["mediaId"] as? String,
               let success = json["success"] as? Bool, success {
                self.mediaItems.removeAll { $0.id == mediaId }
            }

        case "FILE_CHUNK":
            if let transferId = json["transferId"] as? String,
               let b64 = json["dataBase64"] as? String,
               let chunkData = Data(base64Encoded: b64) {
                var current = incomingTransfers[transferId] ?? Data()
                current.append(chunkData)
                incomingTransfers[transferId] = current
            }

        case "FILE_TRANSFER_COMPLETE":
            if let transferId = json["transferId"] as? String,
               let fullData = incomingTransfers.removeValue(forKey: transferId) {
                saveDownloadedFileToDownloads(transferId: transferId, data: fullData)
            }

        default:
            break
        }
    }

    /**
     * WHAT IT DOES:
     *   Parses incoming `NOTIFICATION_EVENT` frames and updates the notification list.
     *
     * HOW IT DOES IT:
     *   - If `eventType == "REMOVED"`, deletes matching notification by key.
     *   - If `POSTED`, extracts title, body, app name, and quick-reply action options.
     *   - Inserts notification at index 0 of `notifications` array.
     *   - Calls `onMirroredNotificationPosted` callback to trigger native macOS banner.
     *
     * WHY IT DOES IT:
     *   Maintains synchronized notification state and surfaces desktop banner alerts.
     */
    private func handleNotificationFrame(_ json: [String: Any]) {
        guard let eventType = json["eventType"] as? String else { return }

        if eventType == "ALL_CLEARED" {
            notifications.removeAll()
            return
        }

        guard let key = json["notificationKey"] as? String else { return }

        if eventType == "REMOVED" {
            notifications.removeAll { $0.id == key }
            return
        }

        var appName = json["appName"] as? String ?? ""
        let pkg = json["packageName"] as? String ?? ""
        if appName.isEmpty || appName.starts(with: "com.") || appName.starts(with: "org.") {
            appName = cleanPackageName(pkg)
        }

        let title = json["title"] as? String ?? ""
        let body = json["body"] as? String ?? ""
        let postTime = (json["postTimeMs"] as? NSNumber)?.int64Value ?? 0

        // Parse optional high-definition app icon PNG/WebP bytes
        let iconB64 = json["appIconBase64"] as? String
        let iconData = iconB64.flatMap { Data(base64Encoded: $0) }

        var parsedActions: [NotificationActionOption] = []
        if let rawActions = json["actions"] as? [[String: Any]] {
            for act in rawActions {
                parsedActions.append(
                    NotificationActionOption(
                        id: act["actionId"] as? String ?? "act_0",
                        title: act["title"] as? String ?? "Reply",
                        supportsInlineReply: act["supportsInlineReply"] as? Bool ?? false,
                        replyPlaceholder: act["replyPlaceholder"] as? String ?? "Reply..."
                    )
                )
            }
        }

        let item = MirroredNotification(
            id: key,
            appName: appName,
            packageName: pkg,
            title: title,
            body: body,
            postTimeMs: postTime,
            appIconData: iconData,
            actions: parsedActions
        )

        notifications.removeAll { $0.id == key }
        notifications.insert(item, at: 0)
        onMirroredNotificationPosted?(item)
    }

    /**
     * WHAT IT DOES: Cleans and humanizes an Android package name into a readable app title.
     * HOW IT DOES IT: Matches known popular package names or capitalizes domain segments.
     * WHY IT DOES IT: Ensures desktop UI never shows raw identifiers like "com.whatsapp".
     */
    private func cleanPackageName(_ pkg: String) -> String {
        let known = [
            "com.whatsapp": "WhatsApp",
            "com.whatsapp.w4b": "WhatsApp Business",
            "com.instagram.android": "Instagram",
            "com.google.android.youtube": "YouTube",
            "com.google.android.gm": "Gmail",
            "com.google.android.apps.messaging": "Messages",
            "com.android.mms": "Messages",
            "org.telegram.messenger": "Telegram",
            "com.twitter.android": "X (Twitter)",
            "com.facebook.katana": "Facebook",
            "com.facebook.orca": "Messenger",
            "com.spotify.music": "Spotify",
            "com.slack": "Slack",
            "com.discord": "Discord",
            "com.google.android.dialer": "Phone",
            "com.android.dialer": "Phone",
            "com.android.chrome": "Chrome",
            "com.google.android.calendar": "Google Calendar",
            "com.google.android.apps.photos": "Google Photos",
            "com.snapchat.android": "Snapchat",
            "com.linkedin.android": "LinkedIn",
            "com.reddit.frontpage": "Reddit",
            "com.amazon.mShop.android.shopping": "Amazon",
            "com.uber.m2": "Uber",
            "com.ubercab": "Uber",
            "com.netflix.ninja": "Netflix",
            "com.netflix.mediaclient": "Netflix"
        ]
        if let match = known[pkg] { return match }

        let segments = pkg.split(separator: ".")
        if let last = segments.last {
            let candidate = last.replacingOccurrences(of: "android", with: "", options: .caseInsensitive)
            if !candidate.isEmpty {
                return candidate.prefix(1).uppercased() + candidate.dropFirst()
            }
        }
        return pkg.isEmpty ? "Android" : pkg
    }

    /**
     * WHAT IT DOES:
     *   Deserializes photo metadata and base64 WebP thumbnail data from Android.
     *
     * HOW IT DOES IT:
     *   Iterates the items array, extracts metadata, converts `thumbnailWebpBase64`
     *   into raw binary `Data`, and populates `@Published mediaItems`.
     *
     * WHY IT DOES IT:
     *   Feeds the SwiftUI photo gallery grid with lightweight thumbnails.
     */
    private func handleMediaIndexResponse(_ json: [String: Any]) {
        if let total = json["totalCount"] as? Int {
            self.totalMediaCount = total
        }

        guard let items = json["items"] as? [[String: Any]] else { return }
        var parsed: [RemoteMediaItem] = []

        for raw in items {
            let id = raw["mediaId"] as? String ?? UUID().uuidString
            let name = raw["displayName"] as? String ?? "Photo.jpg"
            let mime = raw["mimeType"] as? String ?? "image/jpeg"
            let size = (raw["sizeBytes"] as? NSNumber)?.int64Value ?? 0
            let w = raw["width"] as? Int ?? 0
            let h = raw["height"] as? Int ?? 0
            let thumbB64 = raw["thumbnailWebpBase64"] as? String ?? ""
            let thumbData = thumbB64.isEmpty ? nil : Data(base64Encoded: thumbB64)

            parsed.append(
                RemoteMediaItem(
                    id: id,
                    displayName: name,
                    mimeType: mime,
                    sizeBytes: size,
                    width: w,
                    height: h,
                    thumbnailData: thumbData
                )
            )
        }

        var map = [String: RemoteMediaItem]()
        for item in self.mediaItems {
            map[item.id] = item
        }
        for item in parsed {
            map[item.id] = item
        }
        self.mediaItems = map.values.sorted {
            (Int64($0.id) ?? 0) > (Int64($1.id) ?? 0)
        }

        // Automatic batch pagination when Sync All Gallery is running
        if isSyncingAllMedia, let total = totalMediaCount, self.mediaItems.count < total, !parsed.isEmpty {
            requestMediaIndex(offset: self.mediaItems.count, limit: 100)
        } else {
            self.isSyncingAllMedia = false
        }
    }

    // =========================================================================
    // MARK: - 5. Outbound Commands & Requests
    // =========================================================================

    /**
     * WHAT IT DOES: Sends initial pairing handshake packet to Android.
     * HOW IT DOES IT: Transmits `PAIRING_HANDSHAKE` frame with local Mac hostname.
     * WHY IT DOES IT: Identifies the macOS client to the Android daemon.
     */
    private func sendPairingHandshake() {
        let hostName = Host.current().localizedName ?? "Mac"
        sendControlJSON([
            "type": "PAIRING_HANDSHAKE",
            "deviceId": UUID().uuidString,
            "deviceName": hostName,
            "platform": "macos"
        ])
    }

    /**
     * WHAT IT DOES: Maintains active socket keepalive and queries phone battery.
     * HOW IT DOES IT: Schedules a 5.0s repeating timer emitting `HEARTBEAT_PING`.
     * WHY IT DOES IT: Prevents OS socket timeouts and keeps battery % updated.
     */
    private func startHeartbeatLoop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendControlJSON([
                    "type": "HEARTBEAT_PING",
                    "clientTimeMs": Int64(Date().timeIntervalSince1970 * 1000)
                ])
            }
        }
    }

    /**
     * WHAT IT DOES: Sends an inline text reply to an Android notification.
     * HOW IT DOES IT: Sends `NOTIFICATION_ACTION` with `inlineReplyText`.
     * WHY IT DOES IT: Triggers Android's `RemoteInput` intent execution.
     */
    public func sendNotificationReply(notificationKey: String, actionId: String, replyText: String) {
        sendControlJSON([
            "type": "NOTIFICATION_ACTION",
            "notificationKey": notificationKey,
            "actionId": actionId,
            "inlineReplyText": replyText,
            "dismissOnly": false
        ])
    }

    /**
     * WHAT IT DOES: Dismisses a notification remotely from macOS.
     * HOW IT DOES IT: Emits `NOTIFICATION_ACTION` with `dismissOnly: true`.
     * WHY IT DOES IT: Clears the notification on the phone's status bar.
     */
    public func dismissNotification(notificationKey: String) {
        sendControlJSON([
            "type": "NOTIFICATION_ACTION",
            "notificationKey": notificationKey,
            "actionId": "",
            "dismissOnly": true
        ])
        notifications.removeAll { $0.id == notificationKey }
    }

    /**
     * WHAT IT DOES: Requests Android to push all current active notifications.
     * HOW IT DOES IT: Emits `NOTIFICATIONS_SYNC_REQUEST`.
     * WHY IT DOES IT: Hydrates the notification list on connection without waiting
     *                 for new notifications to be posted.
     */
    public func requestNotificationSync() {
        sendControlJSON([
            "type": "NOTIFICATIONS_SYNC_REQUEST"
        ])
    }

    /**
     * WHAT IT DOES: Requests a batch of camera roll thumbnails from Android.
     * HOW IT DOES IT: Emits `MEDIA_INDEX_REQUEST` with offset and limit parameters.
     * WHY IT DOES IT: Allows paginated photo gallery loading on demand.
     */
    /**
     * WHAT IT DOES: Requests a batch of camera roll thumbnails from Android.
     * HOW IT DOES IT: Emits `MEDIA_INDEX_REQUEST` with offset and limit parameters.
     * WHY IT DOES IT: Allows paginated photo gallery loading on demand.
     */
    public func requestMediaIndex(offset: Int = 0, limit: Int = 50) {
        sendControlJSON([
            "type": "MEDIA_INDEX_REQUEST",
            "offset": offset,
            "limit": limit,
            "includeThumbnails": true
        ])
    }

    /**
     * WHAT IT DOES: Starts continuous batch pagination to sync the entire phone gallery.
     * HOW IT DOES IT: Sets isSyncingAllMedia = true and initiates requestMediaIndex from offset 0.
     * WHY IT DOES IT: Fulfills user request to sync all photos from Android seamlessly.
     */
    public func syncAllGallery() {
        isSyncingAllMedia = true
        requestMediaIndex(offset: 0, limit: 100)
    }

    /**
     * WHAT IT DOES: Requests deletion of a photo from Android MediaStore.
     * HOW IT DOES IT: Emits MEDIA_DELETE_REQUEST and removes item optimistically.
     * WHY IT DOES IT: Allows users to manage and delete unwanted photos from Mac.
     */
    public func deleteMediaItem(mediaId: String) {
        guard let numericId = Int64(mediaId) else { return }
        sendControlJSON([
            "type": "MEDIA_DELETE_REQUEST",
            "mediaId": numericId
        ])
        self.mediaItems.removeAll { $0.id == mediaId }
    }

    /**
     * WHAT IT DOES: Resolves local downloaded file URL for a given media item if present.
     * HOW IT DOES IT: Checks downloadedMediaFiles map and standard ~/Downloads directory.
     * WHY IT DOES IT: Powers 1-click native macOS Share Sheet (AirDrop, Messages, Mail).
     */
    public func localFileURL(for mediaId: String) -> URL? {
        if let direct = downloadedMediaFiles[mediaId], FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return nil
        }
        let candidates = [
            downloadsURL.appendingPathComponent("media_\(mediaId).jpg"),
            downloadsURL.appendingPathComponent("\(mediaId).jpg")
        ]
        for c in candidates {
            if FileManager.default.fileExists(atPath: c.path) {
                return c
            }
        }
        return nil
    }

    /**
     * WHAT IT DOES: Requests chunked streaming download of a full-resolution photo.
     * HOW IT DOES IT: Sends `MEDIA_DOWNLOAD_REQUEST` with numeric media ID.
     * WHY IT DOES IT: Fetches original photo bytes on user demand.
     */
    public func downloadFullResolutionMedia(mediaId: String) {
        guard let numericId = Int64(mediaId) else { return }
        let transferId = "media_\(mediaId)"
        sendControlJSON([
            "type": "MEDIA_DOWNLOAD_REQUEST",
            "mediaId": numericId,
            "transferId": transferId
        ])
    }

    /**
     * WHAT IT DOES: Saves completed chunked download bytes to user's ~/Downloads directory.
     * HOW IT DOES IT: Writes data to `FileManager.default.urls(for: .downloadsDirectory)`.
     * WHY IT DOES IT: Delivers downloaded photos directly to standard user download storage.
     */
    private func saveDownloadedFileToDownloads(transferId: String, data: Data) {
        guard let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            return
        }
        let targetURL = downloadsURL.appendingPathComponent("\(transferId).jpg")
        try? data.write(to: targetURL)
        let mediaId = transferId.replacingOccurrences(of: "media_", with: "")
        self.downloadedMediaFiles[mediaId] = targetURL
    }

    /**
     * WHAT IT DOES: Sends instruction to Android to clear all clearable notifications.
     * HOW IT DOES IT: Emits NOTIFICATION_CLEAR_ALL frame and clears local array.
     * WHY IT DOES IT: Keeps notification states strictly in sync with a single gesture.
     */
    public func clearAllNotificationsOnAndroid() {
        sendControlJSON([
            "type": "NOTIFICATION_CLEAR_ALL"
        ])
        self.notifications.removeAll()
    }

    /**
     * WHAT IT DOES: Dismisses a single notification on Android by key.
     * HOW IT DOES IT: Sends NOTIFICATION_DISMISS with key and removes locally.
     * WHY IT DOES IT: Enables 1-click single notification dismissal.
     */
    public func dismissNotificationOnAndroid(key: String) {
        sendControlJSON([
            "type": "NOTIFICATION_DISMISS",
            "key": key
        ])
        self.notifications.removeAll { $0.id == key }
    }

    /**
     * -------------------------------------------------------------------------
     * startCameraStream: Live Continuity Camera Stream Requester
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Requests Android to start capturing and streaming camera frames.
     * HOW IT DOES IT: Sends `CAMERA_CONTROL` with action `"START"` and target lens,
     *                 and updates `isCameraSwitching` state flag.
     * WHY IT DOES IT: Activates remote phone camera for desktop viewing.
     * -------------------------------------------------------------------------
     */
    public func startCameraStream(lens: String = "BACK") {
        currentCameraLens = lens
        isCameraStreaming = true
        isCameraSwitching = true
        cameraErrorMessage = nil
        sendControlJSON([
            "type": "CAMERA_CONTROL",
            "action": "START",
            "lens": lens
        ])
    }

    /**
     * -------------------------------------------------------------------------
     * stopCameraStream: Live Continuity Camera Stream Terminate
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Requests Android to halt camera capture and release hardware.
     * HOW IT DOES IT: Sends `CAMERA_CONTROL` with action `"STOP"` and resets switching flags.
     * WHY IT DOES IT: Saves battery and releases camera device on Android.
     * -------------------------------------------------------------------------
     */
    public func stopCameraStream() {
        isCameraStreaming = false
        isCameraSwitching = false
        sendControlJSON([
            "type": "CAMERA_CONTROL",
            "action": "STOP",
            "lens": currentCameraLens
        ])
    }

    /**
     * -------------------------------------------------------------------------
     * switchCameraLens: Camera Lens Switcher (Front vs Back)
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Switches Android camera lens between Front (Selfie) and Back (Main).
     * HOW IT DOES IT: Sets `isCameraSwitching = true`, clears error message,
     *                 and sends `CAMERA_CONTROL` with action `"SWITCH_LENS"`.
     * WHY IT DOES IT: Enables toggling between webcam face view and desk/environment view.
     * -------------------------------------------------------------------------
     */
    public func switchCameraLens(_ lens: String) {
        currentCameraLens = lens
        isCameraSwitching = true
        cameraErrorMessage = nil
        sendControlJSON([
            "type": "CAMERA_CONTROL",
            "action": "SWITCH_LENS",
            "lens": lens
        ])
    }

    /**
     * -------------------------------------------------------------------------
     * toggleCameraLens: 1-Click FaceTime Style Camera Flip
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Toggles between Front and Back camera feeds.
     * HOW IT DOES IT: Alternates currentCameraLens ("FRONT" <-> "BACK") and dispatches switchCameraLens.
     * WHY IT DOES IT: Powers the FaceTime-style camera flip button on macOS.
     * -------------------------------------------------------------------------
     */
    public func toggleCameraLens() {
        let target = (currentCameraLens == "BACK") ? "FRONT" : "BACK"
        switchCameraLens(target)
    }

    /**
     * -------------------------------------------------------------------------
     * sendClipboardText: Manual Clipboard Content Dispatcher
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Pushes a custom text string directly to the Android clipboard.
     * HOW IT DOES IT: Hashes string via SHA-256 and sends `CLIPBOARD_EVENT`.
     * WHY IT DOES IT: Allows direct manual clipboard push from the macOS UI.
     * -------------------------------------------------------------------------
     */
    public func sendClipboardText(_ text: String) {
        guard !text.isEmpty else { return }
        let digest = SHA256.hash(data: Data(text.utf8))
        let shaHex = digest.map { String(format: "%02x", $0) }.joined()
        lastSyncedClipboardText = text
        if !clipboardSyncHistory.contains(text) {
            clipboardSyncHistory.insert(text, at: 0)
        }
        sendControlJSON([
            "type": "CLIPBOARD_EVENT",
            "contentType": "PLAIN_TEXT",
            "textValue": text,
            "contentSha256": shaHex
        ])
    }

    /**
     * -------------------------------------------------------------------------
     * connectViaQRPayload: Out-of-Band QR Code Connection Initializer
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Parses cryptographic QR pairing descriptor from Android
     *               and connects directly to the phone's LAN IP or fallback.
     * HOW IT DOES IT:
     *   1. Deserializes JSON payload extracting `ips`, `port`, `certFp`, `nonce`, and `name`.
     *   2. Selects the primary non-loopback IP address from `ips` array.
     *   3. Sets `pinnedCertFingerprint = certFp`.
     *   4. Initiates direct TCP connection via `connectDirect(host: ip, port: port)`.
     * WHY IT DOES IT: Eliminates all manual typing of IP addresses and establishes
     *                 cryptographic certificate pinning in a single gesture.
     * -------------------------------------------------------------------------
     */
    public func connectViaQRPayload(_ qrJsonString: String) -> Bool {
        guard let data = qrJsonString.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        let name = json["name"] as? String ?? "Android Device"
        let port = (json["port"] as? NSNumber)?.uint16Value ?? 8765
        let certFp = json["certFp"] as? String
        let ips = json["ips"] as? [String] ?? []

        // Choose best IP: prefer non-loopback LAN IP, fallback to 127.0.0.1
        let targetHost = ips.first(where: { !$0.starts(with: "127.") }) ?? ips.first ?? "127.0.0.1"

        self.connectedDeviceName = name
        self.connectDirect(host: targetHost, port: port, pinnedCertFingerprint: certFp)
        return true
    }

    /**
     * -------------------------------------------------------------------------
     * decodeQRCode: QR Code Image Extractor using CoreImage
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Decodes a QR code string from any NSImage.
     * HOW IT DOES IT: Converts NSImage to CIImage and runs CIDetector(ofType: CIDetectorTypeQRCode).
     * WHY IT DOES IT: Enables scanning QR codes from camera snapshots, screenshots, or files.
     * -------------------------------------------------------------------------
     */
    public static func decodeQRCode(from image: NSImage) -> String? {
        guard let tiffData = image.tiffRepresentation,
              let ciImage = CIImage(data: tiffData) else {
            return nil
        }
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: ciImage) as? [CIQRCodeFeature]
        return features?.first?.messageString
    }

    /**
     * -------------------------------------------------------------------------
     * orientedImage: Hardware Orientation & EXIF Transform Processor
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Creates an NSImage oriented to match physical device tilt.
     * HOW IT DOES IT:
     *   1. Uses CGImageSourceCreateThumbnailWithTransform to apply EXIF tags.
     *   2. Fallback: applies manual degree rotation if EXIF is absent.
     * WHY IT DOES IT: Guarantees camera video matches Android device orientation.
     * -------------------------------------------------------------------------
     */
    public static func orientedImage(from data: Data, fallbackRotation: Int = 0) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return NSImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1920
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        guard let base = NSImage(data: data) else { return nil }
        return fallbackRotation != 0 ? base.rotated(by: CGFloat(fallbackRotation)) : base
    }
}

extension NSImage {
    func rotated(by degrees: CGFloat) -> NSImage {
        let normalized = (Int(degrees) % 360 + 360) % 360
        guard normalized != 0 else { return self }
        let isPerpendicular = (normalized == 90 || normalized == 270)
        let newSize = isPerpendicular ? CGSize(width: self.size.height, height: self.size.width) : self.size
        let rotatedImage = NSImage(size: newSize)
        rotatedImage.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: newSize.width / 2, yBy: newSize.height / 2)
        transform.rotate(byDegrees: CGFloat(normalized))
        transform.translateX(by: -self.size.width / 2, yBy: -self.size.height / 2)
        transform.concat()
        self.draw(at: .zero, from: NSRect(origin: .zero, size: self.size), operation: .copy, fraction: 1.0)
        rotatedImage.unlockFocus()
        return rotatedImage
    }
}
