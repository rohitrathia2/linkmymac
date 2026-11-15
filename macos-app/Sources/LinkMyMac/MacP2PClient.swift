import Foundation
import Network
import CryptoKit
import Combine
import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

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
    public var durationMs: Int64 = 0
    /// Android storage folder, e.g. "Camera" at "DCIM/Camera/" (for Group by Folder).
    public var folderName: String = ""
    public var folderPath: String = ""

    public var isVideo: Bool { mimeType.hasPrefix("video/") }
}

/// Photos and videos are indexed, counted and synced separately (one sidebar section each).
/// Raw values are the phone's `mediaType` filter.
public enum MediaKind: String, Sendable, CaseIterable {
    case photos = "image"
    case videos = "video"
}

/**
 * -----------------------------------------------------------------------------
 * FileTransfer: One row in the File Sharing list (either direction)
 * -----------------------------------------------------------------------------
 */
public struct FileTransfer: Identifiable, Sendable {
    public enum Direction: Sendable { case toPhone, fromPhone }
    public enum Status: Sendable, Equatable { case inProgress, done, failed(String) }

    public let id: String
    public let name: String
    public let direction: Direction
    public let totalBytes: Int64
    public var bytesTransferred: Int64 = 0
    public var status: Status = .inProgress
    public var localURL: URL? = nil
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
    @Published public private(set) var mediaTotals: [MediaKind: Int] = [:]
    @Published public private(set) var syncingKind: MediaKind? = nil
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

    // Pairing: nothing is exchanged until both sides prove they share a secret (WIRE_SPEC.md §3)
    @Published public private(set) var isPaired: Bool = false
    @Published public private(set) var needsPairingCode: Bool = false
    @Published public private(set) var pairingError: String? = nil

    // File sharing, both directions, newest first
    @Published public private(set) var transfers: [FileTransfer] = []

    // Network Engine Components
    nonisolated static let lastHostKey = "LinkMyMac.lastDirectHost"
    private var browser: NWBrowser?
    private var connection: NWConnection?
    /// Bumped whenever `connection` is replaced or torn down. Callbacks from an older
    /// connection compare against it and bail out instead of killing the live one.
    private var connectionGeneration = 0
    private var isTransportReady = false
    private var heartbeatTimer: Timer?
    private var autoReconnectTimer: Timer?
    private var lastDirectHost: String? = UserDefaults.standard.string(forKey: MacP2PClient.lastHostKey) ?? "127.0.0.1"
    private var lastDirectPort: UInt16? = 8765
    private var receiveBuffer = Data()
    private let networkQueue = DispatchQueue(label: "com.linkmymac.network", qos: .userInitiated)

    // Authentication state for the current connection
    // ponytail: secrets live in UserDefaults; move them to the Keychain once the app is Developer ID–signed
    private static let deviceIdKey = "LinkMyMac.deviceId"
    private static let pairedPhonesKey = "LinkMyMac.pairedPhones" // phoneId -> base64 secret
    private lazy var deviceId: String = {
        if let id = UserDefaults.standard.string(forKey: Self.deviceIdKey) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: Self.deviceIdKey)
        return id
    }()
    private lazy var macName = Host.current().localizedName ?? "Mac"
    private var challenge: (phoneId: String, nonce: String)?
    private var macNonce = ""
    private var pairingKey: P256.KeyAgreement.PrivateKey?
    private var pendingPairingCode: String?
    private var awaitingAck = false

    // Files arriving from the phone, streamed to a temp file until complete
    private struct IncomingFile {
        let handle: FileHandle
        let tempURL: URL
        let name: String
        var nextChunk = 0
        var bytes: Int64 = 0
    }
    private var incomingFiles: [String: IncomingFile] = [:]

    // Video streaming: byte ranges in flight -> the player's loader waiting for them
    private var mediaRangeSinks: [String: (MediaRangeEvent) -> Void] = [:]

    // Subsystem Callbacks
    public var onRemoteClipboardReceived: ((String, String) -> Void)?
    public var onMirroredNotificationPosted: ((MirroredNotification) -> Void)?
    public var onMediaControlCommandReceived: ((String) -> Void)?
    public var onConnected: (() -> Void)?
    public var onFileReceived: ((URL) -> Void)?

    /// SMS, calls, screen mirroring + control, hotspot (PhoneFeatures.swift)
    let phone = PhoneFeatures()

    public init() {
        phone.client = self
        startDiscovery()
        // The first direct connection (last used host, USB tunnel by default) is opened by AppDelegate.
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
    public func connectDirect(host: String, port: UInt16) {
        lastDirectHost = host
        lastDirectPort = port
        UserDefaults.standard.set(host, forKey: Self.lastHostKey)
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
                self.reconnect()
            }
        }
    }

    /// Where a reconnect goes when no Bonjour peer is visible (127.0.0.1 = USB via adb forward).
    public var directEndpointLabel: String {
        "\(lastDirectHost ?? "127.0.0.1"):\(lastDirectPort ?? 8765)"
    }

    /// Bonjour peer if one is visible, otherwise the last direct host (USB tunnel by default).
    public func reconnect() {
        if let peer = discoveredPeers.first {
            print("[MacP2PClient] Auto-connecting to wireless peer \(peer.name)...")
            connect(to: peer)
        } else {
            connectDirect(host: lastDirectHost ?? "127.0.0.1", port: lastDirectPort ?? 8765)
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
        let generation = connectionGeneration

        conn.stateUpdateHandler = { [weak self] state in
            print("[MacP2PClient] Socket state changed: \(state)")
            Task { @MainActor in
                // A replaced connection still reports .cancelled/.failed later on.
                // Acting on that would tear down the connection that replaced it.
                guard let self, generation == self.connectionGeneration else { return }
                switch state {
                case .ready:
                    self.autoReconnectTimer?.invalidate()
                    self.autoReconnectTimer = nil
                    self.isTransportReady = true
                    self.connectionState = "Verifying phone..."
                    self.connectedDeviceName = displayLabel
                    self.startHeartbeatLoop()
                    self.receiveNextChunk()
                    // The phone speaks first with AUTH_CHALLENGE; data starts after handlePairingAck.
                case .failed(let error):
                    self.disconnect()
                    self.connectionState = "Connecting (auto-retry): \(error.localizedDescription)"
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
        connectionGeneration += 1 // anything still in flight from this connection is now stale
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        connection?.cancel()
        connection = nil
        receiveBuffer.removeAll()
        isTransportReady = false
        isPaired = false
        awaitingAck = false
        challenge = nil
        pairingKey = nil
        syncingKind = nil // otherwise the Sync spinner would spin forever after a drop
        let openRanges = mediaRangeSinks.values
        mediaRangeSinks.removeAll()
        openRanges.forEach { $0(.done(error: "Connection lost")) } // the player shows an error instead of hanging
        failUnfinishedTransfers(reason: "Connection lost")
        phone.connectionLost()
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
        // Clipboard, replies, media commands... never leave this Mac before the phone is verified.
        guard isPaired else { return false }
        return sendFrame(dict)
    }

    /// Transport-level send, also used before pairing (handshake, heartbeats).
    @discardableResult
    private func sendFrame(_ dict: [String: Any]) -> Bool {
        guard let conn = connection, isTransportReady, let frame = try? Self.frame(dict) else {
            return false
        }
        conn.send(content: frame, completion: .contentProcessed { _ in })
        return true
    }

    /// `[0x4C 0x4D "LM"][flags 0x0001 = JSON][uint32 BE length][payload]`
    nonisolated static func frame(_ dict: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: dict)
        var frame = Data([0x4C, 0x4D, 0x00, 0x01])
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
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
        let generation = connectionGeneration

        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                // A cancelled connection completes its pending receive with an error;
                // without this check that error would disconnect the *new* connection.
                guard let self, generation == self.connectionGeneration else { return }
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
            guard length <= 16 << 20 else {
                // Same 16 MB cap as Android; an unverified peer could otherwise make us buffer gigabytes.
                disconnect()
                scheduleAutoReconnect()
                return
            }

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

        // Until the phone proves it holds our shared secret, only the handshake counts.
        // Otherwise anything on the network advertising _linkmymac._tcp could push
        // clipboard text, fake notifications or files into this Mac.
        guard isPaired || type == "AUTH_CHALLENGE" || type == "PAIRING_ACK" else { return }

        switch type {
        case "AUTH_CHALLENGE":
            guard !isPaired, let phoneId = json["phoneId"] as? String, let nonce = json["nonce"] as? String else { return }
            challenge = (phoneId, nonce)
            if let name = json["phoneName"] as? String {
                connectedDeviceName = name
            }
            answerChallenge()

        case "PAIRING_ACK":
            handlePairingAck(json)

        case "FILE_OFFER":
            beginIncomingFile(json)

        case "FILE_CHUNK":
            appendIncomingFile(json)

        case "FILE_TRANSFER_COMPLETE":
            finishIncomingFile(json)

        case "MEDIA_RANGE_DATA":
            if let id = json["requestId"] as? String, let sink = mediaRangeSinks[id],
               let data = (json["dataBase64"] as? String).flatMap({ Data(base64Encoded: $0) }) {
                sink(.data(data))
            }

        case "MEDIA_RANGE_DONE":
            if let id = json["requestId"] as? String, let sink = mediaRangeSinks.removeValue(forKey: id) {
                sink(.done(error: json["error"] as? String))
            }

        case "FILE_TRANSFER_RESULT":
            // The phone's verdict on a file we sent it.
            if let id = json["transferId"] as? String {
                let ok = json["ok"] as? Bool == true
                updateTransfer(id) { $0.status = ok ? .done : .failed(json["error"] as? String ?? "Phone couldn't save it") }
            }

        case "HEARTBEAT_PONG":
            if let pct = json["batteryPercent"] as? Int {
                self.remoteBatteryPercent = pct
            }
            phone.updateNetwork(json)

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

        default:
            _ = phone.handle(type, json) // SMS, calls, mirroring, control, hotspot
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
        let kind = (json["mediaType"] as? String).flatMap(MediaKind.init(rawValue:))
        if let kind, let total = json["totalCount"] as? Int {
            mediaTotals[kind] = total
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
                    thumbnailData: thumbData,
                    durationMs: (raw["durationMs"] as? NSNumber)?.int64Value ?? 0,
                    folderName: raw["bucket"] as? String ?? "",
                    folderPath: raw["relativePath"] as? String ?? ""
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

        // "Sync All" keeps paging through one kind until it's fully indexed.
        if let kind, kind == syncingKind, let total = mediaTotals[kind] {
            let loaded = mediaItems(kind).count
            if loaded < total, !parsed.isEmpty {
                requestMediaIndex(kind, offset: loaded, limit: 100)
            } else {
                syncingKind = nil
            }
        }
    }

    public func mediaItems(_ kind: MediaKind) -> [RemoteMediaItem] {
        mediaItems.filter { $0.isVideo == (kind == .videos) }
    }

    // =========================================================================
    // MARK: - 5. Outbound Commands & Requests
    // =========================================================================

    // =========================================================================
    // MARK: - Pairing & Authentication (WIRE_SPEC.md §3)
    // =========================================================================

    /**
     * Answers the phone's AUTH_CHALLENGE: with an HMAC proof if we're already paired
     * with this phone, with the pairing code + an ephemeral ECDH key if the user gave
     * us one, otherwise by asking the user for the code shown on the phone.
     */
    private func answerChallenge() {
        guard let challenge else { return }
        macNonce = Self.randomHex(16)
        var handshake: [String: Any] = [
            "type": "PAIRING_HANDSHAKE",
            "deviceId": deviceId,
            "deviceName": macName,
            "platform": "macos",
            "macNonce": macNonce
        ]
        if let secret = pairedSecret(for: challenge.phoneId) {
            handshake["proof"] = Self.proof(secret, role: "mac", nonce: challenge.nonce)
        } else if let code = pendingPairingCode {
            pendingPairingCode = nil
            let key = P256.KeyAgreement.PrivateKey()
            pairingKey = key
            handshake["pairingCode"] = code
            handshake["macPublicKey"] = key.publicKey.derRepresentation.base64EncodedString()
        } else {
            needsPairingCode = true
            connectionState = "Pairing required"
            return
        }
        awaitingAck = sendFrame(handshake)
    }

    /// Called by the pairing prompt. Used right away, or on the next challenge if we're offline.
    public func submitPairingCode(_ code: String) {
        pairingError = nil
        pendingPairingCode = code
        if challenge != nil, !awaitingAck {
            answerChallenge()
        }
    }

    private func handlePairingAck(_ json: [String: Any]) {
        guard awaitingAck, let challenge else { return }
        awaitingAck = false
        let usedPairingKey = pairingKey
        pairingKey = nil

        guard json["accepted"] as? Bool == true else {
            if usedPairingKey == nil {
                savePairedSecret(nil, for: challenge.phoneId) // the phone forgot this Mac
            }
            needsPairingCode = true
            connectionState = "Pairing required"
            switch json["error"] as? String {
            case "INVALID_CODE": pairingError = "Wrong code. Check the phone and try again."
            case "RATE_LIMITED": pairingError = "Too many attempts. Wait a few seconds and retry."
            default: pairingError = usedPairingKey == nil ? "This phone no longer trusts this Mac. Enter its code to pair again." : nil
            }
            return
        }

        // New pairing: derive the secret from ECDH. Reconnect: use the stored one.
        var secret = pairedSecret(for: challenge.phoneId)
        if let key = usedPairingKey {
            guard let keyData = (json["phonePublicKey"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let phoneKey = try? P256.KeyAgreement.PublicKey(derRepresentation: keyData),
                  let shared = try? key.sharedSecretFromKeyAgreement(with: phoneKey) else {
                pairingError = "Pairing failed. Try again."
                needsPairingCode = true
                return
            }
            secret = Self.hmac(key: shared.withUnsafeBytes { Data($0) }, message: Data("linkmymac-pairing-v1".utf8))
        }

        // The phone must prove it holds the same secret, or it's an impostor.
        guard let secret, (json["proof"] as? String)?.lowercased() == Self.proof(secret, role: "phone", nonce: macNonce) else {
            pairingError = "The phone failed verification."
            disconnect()
            scheduleAutoReconnect()
            return
        }

        if usedPairingKey != nil {
            savePairedSecret(secret, for: challenge.phoneId)
        }
        pendingPairingCode = nil
        isPaired = true
        needsPairingCode = false
        pairingError = nil
        connectionState = "Connected"
        if let deviceName = json["deviceName"] as? String {
            connectedDeviceName = deviceName
        }
        // The phone pushes its notifications itself once we're verified.
        requestMediaIndex(offset: 0, limit: 30)
        phone.loadAll()
        onConnected?()
    }

    private func pairedSecret(for phoneId: String) -> Data? {
        let all = UserDefaults.standard.dictionary(forKey: Self.pairedPhonesKey) as? [String: String]
        return all?[phoneId].flatMap { Data(base64Encoded: $0) }
    }

    private func savePairedSecret(_ secret: Data?, for phoneId: String) {
        var all = UserDefaults.standard.dictionary(forKey: Self.pairedPhonesKey) as? [String: String] ?? [:]
        if let secret {
            all[phoneId] = secret.base64EncodedString()
        } else {
            all.removeValue(forKey: phoneId)
        }
        UserDefaults.standard.set(all, forKey: Self.pairedPhonesKey)
    }

    private nonisolated static func hmac(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// HMAC-SHA256(secret, "<role>|<nonce>") as lowercase hex; must match PairingManager.proof on Android.
    private nonisolated static func proof(_ secret: Data, role: String, nonce: String) -> String {
        hmac(key: secret, message: Data("\(role)|\(nonce)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func randomHex(_ byteCount: Int) -> String {
        (0..<byteCount).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /**
     * WHAT IT DOES: Maintains active socket keepalive and queries phone battery.
     * HOW IT DOES IT: Schedules a 5.0s repeating timer emitting `HEARTBEAT_PING`.
     * WHY IT DOES IT: Prevents OS socket timeouts and keeps battery % updated.
     *                 Also sent before pairing, so the phone's 30 s pre-auth timeout
     *                 doesn't drop us while the user reads the pairing code.
     */
    private func startHeartbeatLoop() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sendFrame([
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
     * WHAT IT DOES: Requests one page of photos or videos (with thumbnails) from Android.
     * HOW IT DOES IT: Emits `MEDIA_INDEX_REQUEST` with `mediaType`, offset and limit.
     *                 With no kind it asks for the first page of each.
     * WHY IT DOES IT: Photos and videos page independently, so the Videos section
     *                 isn't empty just because the newest 1,000 items are photos.
     */
    public func requestMediaIndex(_ kind: MediaKind? = nil, offset: Int = 0, limit: Int = 50) {
        guard let kind else {
            MediaKind.allCases.forEach { requestMediaIndex($0, offset: offset, limit: limit) }
            return
        }
        sendControlJSON([
            "type": "MEDIA_INDEX_REQUEST",
            "mediaType": kind.rawValue,
            "offset": offset,
            "limit": limit,
            "includeThumbnails": true
        ])
    }

    /**
     * WHAT IT DOES: Pages through every photo (or every video) on the phone.
     * HOW IT DOES IT: Sets `syncingKind` and requests offset 0; handleMediaIndexResponse
     *                 requests the next page until the kind's total is reached.
     */
    public func syncAllGallery(_ kind: MediaKind) {
        syncingKind = kind
        requestMediaIndex(kind, offset: 0, limit: 100)
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
        // Downloads are saved as media_<id>.<original extension> (older builds always used .jpg).
        let ext = mediaItems.first(where: { $0.id == mediaId }).map { ($0.displayName as NSString).pathExtension } ?? ""
        let candidates = (ext.isEmpty ? [] : [downloadsURL.appendingPathComponent("media_\(mediaId).\(ext)")]) + [
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
    /// Streams a video from the phone in byte ranges (MEDIA_RANGE_REQUEST), so playback starts
    /// right away. Keep the loader alive while its player is in use; stopAll() when done.
    func makeStreamLoader(for item: RemoteMediaItem) -> MediaStreamLoader? {
        guard let mediaId = Int64(item.id) else { return nil }
        return MediaStreamLoader(
            mimeType: item.mimeType,
            size: item.sizeBytes,
            requestRange: { [weak self] id, offset, length, sink in
                guard let self else { return sink(.done(error: "Closed")) }
                self.mediaRangeSinks[id] = sink
                let sent = self.sendControlJSON([
                    "type": "MEDIA_RANGE_REQUEST", "requestId": id,
                    "mediaId": mediaId, "offset": offset, "length": length
                ])
                if !sent {
                    self.mediaRangeSinks[id] = nil
                    sink(.done(error: "Phone not connected"))
                }
            },
            cancelRange: { [weak self] id in
                guard let self, self.mediaRangeSinks.removeValue(forKey: id) != nil else { return }
                self.sendControlJSON(["type": "MEDIA_RANGE_CANCEL", "requestId": id])
            }
        )
    }

    public func downloadFullResolutionMedia(mediaId: String) {
        guard let numericId = Int64(mediaId) else { return }
        let transferId = "media_\(mediaId)"
        sendControlJSON([
            "type": "MEDIA_DOWNLOAD_REQUEST",
            "mediaId": numericId,
            "transferId": transferId
        ])
    }

    // =========================================================================
    // MARK: - File Sharing (WIRE_SPEC.md §4)
    // =========================================================================

    /// Mac → phone. Files go one after another; each lands in the phone's Download/LinkMyMac.
    public func sendFiles(_ urls: [URL]) {
        guard isPaired, let conn = connection else {
            for url in urls {
                var row = FileTransfer(id: UUID().uuidString, name: url.lastPathComponent, direction: .toPhone,
                                       totalBytes: 0, status: .failed("Phone not connected"))
                row.localURL = url // lets the Files tab offer Retry
                transfers.insert(row, at: 0)
            }
            return
        }
        var jobs: [(id: String, url: URL)] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            var row = FileTransfer(id: UUID().uuidString, name: url.lastPathComponent, direction: .toPhone,
                                   totalBytes: Int64(values?.fileSize ?? 0))
            row.localURL = url // source file: Retry and Show in Finder
            if values?.isDirectory == true {
                row.status = .failed("Folders aren't supported. Zip it first.") // ponytail: zip on the fly if asked
            } else {
                jobs.append((row.id, url))
            }
            transfers.insert(row, at: 0)
        }
        guard !jobs.isEmpty else { return }
        // Off the main actor: reading + base64 of big files shouldn't stall the UI.
        // Strong self is fine, the client is an app-lifetime singleton.
        Task.detached(priority: .userInitiated) { [self] in
            for job in jobs {
                do {
                    try await Self.streamFile(job.url, id: job.id, over: conn) { sent in
                        await self.transferProgress(job.id, bytes: sent)
                    }
                } catch {
                    await self.transferFailed(job.id, reason: error.localizedDescription)
                }
            }
        }
    }

    /// FILE_OFFER → 64 KB FILE_CHUNKs → FILE_TRANSFER_COMPLETE. Each send waits until
    /// Network.framework has taken the bytes, so a 4 GB file never sits in memory.
    private nonisolated static func streamFile(
        _ url: URL, id: String, over conn: NWConnection,
        progress: @Sendable (Int64) async -> Void
    ) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        try await send(["type": "FILE_OFFER", "transferId": id, "fileName": url.lastPathComponent,
                        "mimeType": mime, "totalBytes": size], over: conn)
        var index = 0
        var sent: Int64 = 0
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try await send(["type": "FILE_CHUNK", "transferId": id, "chunkIndex": index,
                            "dataBase64": chunk.base64EncodedString()], over: conn)
            index += 1
            sent += Int64(chunk.count)
            if index % 16 == 0 { await progress(sent) } // UI update every ~1 MB
        }
        try await send(["type": "FILE_TRANSFER_COMPLETE", "transferId": id, "totalChunks": index], over: conn)
        await progress(sent) // stays "in progress" until the phone's FILE_TRANSFER_RESULT
    }

    private nonisolated static func send(_ dict: [String: Any], over conn: NWConnection) async throws {
        let data = try frame(dict)
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            })
        }
    }

    private func transferProgress(_ id: String, bytes: Int64) {
        updateTransfer(id) { $0.bytesTransferred = bytes }
    }

    private func transferFailed(_ id: String, reason: String) {
        updateTransfer(id) { if $0.status == .inProgress { $0.status = .failed(reason) } }
    }

    private func updateTransfer(_ id: String, _ change: (inout FileTransfer) -> Void) {
        guard let index = transfers.firstIndex(where: { $0.id == id }) else { return }
        change(&transfers[index])
    }

    public func clearFinishedTransfers() {
        transfers.removeAll { $0.status != .inProgress }
    }

    // Phone → Mac: written to a temp file, moved into ~/Downloads when complete.
    private func beginIncomingFile(_ json: [String: Any]) {
        guard let id = json["transferId"] as? String, incomingFiles[id] == nil else { return }
        let name = Self.safeFileName(json["fileName"] as? String)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("linkmymac-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: temp) else { return }
        incomingFiles[id] = IncomingFile(handle: handle, tempURL: temp, name: name)
        let total = (json["totalBytes"] as? NSNumber)?.int64Value ?? 0
        transfers.removeAll { $0.id == id } // a re-downloaded photo reuses its transfer id
        transfers.insert(FileTransfer(id: id, name: name, direction: .fromPhone, totalBytes: max(total, 0)), at: 0)
    }

    private func appendIncomingFile(_ json: [String: Any]) {
        guard let id = json["transferId"] as? String, var file = incomingFiles[id] else { return }
        guard json["chunkIndex"] as? Int == file.nextChunk,
              let chunk = (json["dataBase64"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
            return failIncomingFile(id, reason: "Corrupted transfer")
        }
        do {
            try file.handle.write(contentsOf: chunk)
        } catch {
            return failIncomingFile(id, reason: error.localizedDescription)
        }
        file.nextChunk += 1
        file.bytes += Int64(chunk.count)
        incomingFiles[id] = file
        if file.nextChunk % 16 == 0 { transferProgress(id, bytes: file.bytes) }
    }

    private func finishIncomingFile(_ json: [String: Any]) {
        guard let id = json["transferId"] as? String, let file = incomingFiles[id] else { return }
        guard json["totalChunks"] as? Int == file.nextChunk else {
            return failIncomingFile(id, reason: "Transfer incomplete")
        }
        incomingFiles.removeValue(forKey: id)
        try? file.handle.close()
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let destination = Self.uniqueURL(in: downloads, name: file.name)
        do {
            try FileManager.default.moveItem(at: file.tempURL, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: file.tempURL)
            updateTransfer(id) { $0.status = .failed(error.localizedDescription) }
            sendControlJSON(["type": "FILE_TRANSFER_RESULT", "transferId": id, "ok": false, "error": error.localizedDescription])
            return
        }
        updateTransfer(id) {
            $0.status = .done
            $0.bytesTransferred = file.bytes
            $0.localURL = destination
        }
        sendControlJSON(["type": "FILE_TRANSFER_RESULT", "transferId": id, "ok": true])
        if id.hasPrefix("media_") {
            downloadedMediaFiles[String(id.dropFirst("media_".count))] = destination // Photos tab download
        } else {
            onFileReceived?(destination)
        }
    }

    private func failIncomingFile(_ id: String, reason: String) {
        if let file = incomingFiles.removeValue(forKey: id) {
            try? file.handle.close()
            try? FileManager.default.removeItem(at: file.tempURL)
        }
        updateTransfer(id) { $0.status = .failed(reason) }
        sendControlJSON(["type": "FILE_TRANSFER_RESULT", "transferId": id, "ok": false, "error": reason])
    }

    private func failUnfinishedTransfers(reason: String) {
        for (_, file) in incomingFiles {
            try? file.handle.close()
            try? FileManager.default.removeItem(at: file.tempURL)
        }
        incomingFiles.removeAll()
        for index in transfers.indices where transfers[index].status == .inProgress {
            transfers[index].status = .failed(reason)
        }
    }

    /// The name comes from the network: keep a plain file name so it can't escape ~/Downloads.
    private nonisolated static func safeFileName(_ raw: String?) -> String {
        let last = (raw ?? "").components(separatedBy: CharacterSet(charactersIn: "/\\:")).last ?? ""
        let cleaned = String(String.UnicodeScalarView(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "file" : String(cleaned.prefix(200))
    }

    /// Finder-style "name (1).ext" so an incoming file never overwrites an existing one.
    private nonisolated static func uniqueURL(in directory: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
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
     *   3. Keeps the QR's pairing `code` for the phone's next AUTH_CHALLENGE.
     *   4. Initiates direct TCP connection via `connectDirect(host: ip, port: port)`.
     * WHY IT DOES IT: Eliminates manual typing of the IP address and pairing code.
     *                 (The QR's `certFp` is unused until the transport moves to TLS.)
     * -------------------------------------------------------------------------
     */
    public func connectViaQRPayload(_ qrJsonString: String) -> Bool {
        guard let data = qrJsonString.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        let name = json["name"] as? String ?? "Android Device"
        let port = (json["port"] as? NSNumber)?.uint16Value ?? 8765
        let ips = json["ips"] as? [String] ?? []

        // Choose best IP: prefer non-loopback LAN IP, fallback to 127.0.0.1
        let targetHost = ips.first(where: { !$0.starts(with: "127.") }) ?? ips.first ?? "127.0.0.1"

        // The QR carries the pairing code, so the next AUTH_CHALLENGE pairs without typing.
        pendingPairingCode = json["code"] as? String
        self.connectedDeviceName = name
        self.connectDirect(host: targetHost, port: port)
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

#if DEBUG
/// Sample content for checking screens against the Figma design. Debug builds only:
/// run with `LINKMYMAC_PREVIEW=1` (or `=pairing`); no network is used.
enum PreviewArt {
    private static let palettes: [(UInt32, UInt32, UInt32)] = [
        (0xFFB36B, 0xFF5E7E, 0xFFE6A8), (0x9ADCFF, 0x2F80ED, 0xFFFFFF), (0xC9F2D4, 0x5BBE83, 0x1F6B45),
        (0x30307A, 0x0E0F2E, 0xFFF3C4), (0xFFE6AE, 0xF6A65C, 0xD27434), (0xFFE0EC, 0xFF8DB6, 0xFFFFFF),
    ]
    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    /// A gradient "landscape" PNG, standing in for a photo or video frame.
    static func thumbnail(_ index: Int, width: Int = 320, height: Int = 320) -> Data? {
        let (top, bottom, accent) = palettes[index % palettes.count]
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(starting: color(top), ending: color(bottom))?.draw(in: rect, angle: -90)
        color(accent).setFill()
        let d = CGFloat(min(width, height)) * 0.34
        NSBezierPath(ovalIn: NSRect(x: rect.midX - d / 2, y: rect.midY - d * 0.2, width: d, height: d)).fill()
        (color(bottom).blended(withFraction: 0.45, of: .black) ?? .black).setFill()
        NSBezierPath(ovalIn: NSRect(x: -rect.width * 0.3, y: -rect.height * 0.55, width: rect.width * 1.6, height: rect.height * 0.9)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

extension MacP2PClient {
    static var previewMode: String? { ProcessInfo.processInfo.environment["LINKMYMAC_PREVIEW"] }

    /// Fills the UI with sample data (no network) so screens can be checked against the design.
    func loadPreviewData(paired: Bool) {
        stopDiscovery()
        isPaired = paired
        needsPairingCode = !paired
        connectedDeviceName = paired ? "Pixel 8 Pro" : nil
        isWirelessConnection = true
        connectionState = paired ? "Connected" : "Waiting for code"
        discoveredPeers = [DiscoveredPeer(id: "preview", name: "Pixel 8 Pro", endpoint: .hostPort(host: "192.168.1.24", port: 8765))]
        guard paired else { return }
        remoteBatteryPercent = 82
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        func action(_ id: String, _ title: String, reply: Bool = false) -> NotificationActionOption {
            NotificationActionOption(id: id, title: title, supportsInlineReply: reply, replyPlaceholder: reply ? "Reply" : "")
        }
        notifications = [
            MirroredNotification(id: "n1", appName: "Messages", packageName: "messages", title: "Alex Chen", body: "Running 10 min late, sorry!",
                                 postTimeMs: now - 120_000, appIconData: nil, actions: [action("reply", "Reply", reply: true), action("read", "Mark as read")]),
            MirroredNotification(id: "n2", appName: "Calendar", packageName: "calendar", title: "Team standup in 10 minutes", body: "10:30 – 10:45 AM · Video call",
                                 postTimeMs: now - 480_000, appIconData: nil, actions: [action("snooze", "Snooze"), action("dismiss", "Dismiss")]),
            MirroredNotification(id: "n3", appName: "Mail", packageName: "mail", title: "Priya Sharma",
                                 body: "Slides for Thursday — here’s the deck we talked about. Let me know if the numbers in the last section look right before I send it to the team.",
                                 postTimeMs: now - 1_500_000, appIconData: nil, actions: [action("archive", "Archive")]),
            MirroredNotification(id: "n4", appName: "Parcel", packageName: "parcel", title: "Out for delivery", body: "Your parcel arrives today between 2 and 6 PM.",
                                 postTimeMs: now - 3_600_000, appIconData: nil, actions: []),
        ]
        mediaTotals = [.photos: 2481, .videos: 164]
        var items: [RemoteMediaItem] = []
        let folders = [("Camera", "DCIM/Camera/"), ("Screenshots", "Pictures/Screenshots/"), ("Pictures", "Pictures/")]
        for i in 0..<18 {
            var item = RemoteMediaItem(id: "p\(i)", displayName: "IMG_20261115_\(1000 + i).jpg", mimeType: "image/jpeg",
                                       sizeBytes: 3_400_000, width: 4000, height: 3000, thumbnailData: PreviewArt.thumbnail(i))
            let folder = folders[i < 12 ? 0 : i < 14 ? 1 : 2]
            item.folderName = folder.0
            item.folderPath = folder.1
            items.append(item)
        }
        for (i, video) in [("Sunset walk.mp4", 225_000), ("Beach day.mp4", 42_000), ("City lights.mp4", 78_000), ("Forest trail.mp4", 726_000), ("Garden.mp4", 9_000)].enumerated() {
            var item = RemoteMediaItem(id: "v\(i)", displayName: video.0, mimeType: "video/mp4", sizeBytes: 148_000_000,
                                       width: 1920, height: 1080, thumbnailData: PreviewArt.thumbnail(i, width: 320, height: 180))
            item.durationMs = Int64(video.1)
            item.folderName = "Camera"
            item.folderPath = "DCIM/Camera/"
            items.append(item)
        }
        mediaItems = items
        var sending = FileTransfer(id: "t1", name: "Trip itinerary.pdf", direction: .toPhone, totalBytes: 18_000_000)
        sending.bytesTransferred = 12_200_000
        var sent = FileTransfer(id: "t2", name: "Boarding pass.pdf", direction: .toPhone, totalBytes: 1_200_000)
        sent.status = .done
        var failed = FileTransfer(id: "t3", name: "Screen recording.mov", direction: .toPhone, totalBytes: 240_000_000)
        failed.status = .failed("Phone could not create the file")
        failed.localURL = URL(fileURLWithPath: "/tmp/Screen recording.mov")
        var keynote = FileTransfer(id: "t4", name: "Q4 review.key", direction: .toPhone, totalBytes: 48_000_000)
        keynote.status = .done
        var received = FileTransfer(id: "t5", name: "Invoice 0425.pdf", direction: .fromPhone, totalBytes: 220_000)
        received.bytesTransferred = 220_000
        received.status = .done
        transfers = [sending, sent, failed, keynote, received]
        lastSyncedClipboardText = "Order #48213 · pick up after 5 PM"
        clipboardSyncHistory = ["Order #48213 · pick up after 5 PM", "Meet at the café on the 2nd floor — table by the window."]
        isCameraStreaming = true
        currentCameraLens = "BACK"
        latestCameraFrame = PreviewArt.thumbnail(2, width: 640, height: 480).flatMap { NSImage(data: $0) }
        phone.loadPreviewData()
    }
}
#endif
