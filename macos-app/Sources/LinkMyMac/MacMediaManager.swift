import Foundation
import AppKit

/**
 * =============================================================================
 * MacMediaManager: macOS System-Wide Now Playing Media Controller & Bridge
 * =============================================================================
 * WHAT IT DOES:
 *   1. Monitors active media playback across any macOS application (Apple Music,
 *      Spotify, YouTube in Safari/Chrome, Podcasts, QuickTime, VLC, etc.) via
 *      the native macOS MediaRemote framework.
 *   2. Extracts comprehensive playback metadata:
 *      - Track Title, Artist, Album, App Name (e.g. "Google Chrome", "Spotify")
 *      - Live Playback State (Playing vs Paused)
 *      - Track Duration and Elapsed Position
 *   3. Automatically transmits Now Playing metadata to connected Android devices
 *      over P2P (`NOW_PLAYING_UPDATE`).
 *   4. Receives remote media control commands from Android (Play, Pause, Next, Prev,
 *      Toggle Play/Pause) and executes them natively on macOS via MediaRemote and
 *      system media keys.
 *
 * HOW IT DOES IT:
 *   - macOS `mediaremoted` restricts direct playback queue queries (`handlePlaybackQueueRequest`)
 *     to processes possessing Apple platform signatures (returning error code 3
 *     "Operation not permitted" for ad-hoc/developer bundles).
 *   - To bypass this OS sandbox boundary cleanly and sanctioned, `MacMediaManager`
 *     orchestrates a lightweight helper daemon via Apple's signed `/usr/bin/swift`
 *     runtime executing `media_bridge.swift`.
 *   - The helper registers for `kMRMediaRemoteNowPlayingInfoDidChangeNotification`
 *     and streams real-time JSON frames over standard output whenever playback changes.
 *   - Control commands from Android are piped into the helper's standard input to
 *     execute `MRMediaRemoteSendCommand` directly with full platform privileges.
 *   - Employs synthetic hardware media keys (`NX_KEYTYPE_PLAY`, etc.) as an
 *     auxiliary fallback.
 *
 * WHY IT DOES IT:
 *   Delivers the seamless Apple Continuity / Now Playing experience to Android,
 *   allowing users to view and control macOS audio/video directly from their phone's
 *   lock screen, notification panel, and the UniBridge companion application.
 * =============================================================================
 */
@MainActor
public final class MacMediaManager: NSObject {

    private static func logToFile(_ str: String) {
        let line = "\(Date()): \(str)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/linkmymac_media.log")) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: "/tmp/linkmymac_media.log"))
            }
        }
    }

    public struct NowPlayingState: Equatable {
        public var hasMedia: Bool = false
        public var title: String = ""
        public var artist: String = ""
        public var album: String = ""
        public var isPlaying: Bool = false
        public var duration: Double = 0.0
        public var elapsedTime: Double = 0.0
        public var appName: String = "Mac Media"
    }

    private let p2pClient: MacP2PClient
    private var isMonitoring: Bool = false
    private var helperProcess: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var outputBuffer: String = ""

    public private(set) var currentState: NowPlayingState = NowPlayingState()
    private var lastSentState: NowPlayingState = NowPlayingState()
    private var hasSentInitialConnectedState: Bool = false

    public init(p2pClient: MacP2PClient) {
        self.p2pClient = p2pClient
        super.init()
    }

    deinit {
        // Synchronous cleanup of helper process
        stdinPipe?.fileHandleForWriting.closeFile()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        helperProcess?.terminate()
    }

    /**
     * -------------------------------------------------------------------------
     * helperScriptSource: Embedded Swift MediaRemote Helper Daemon
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Self-contained script run by Apple-signed `/usr/bin/swift`.
     * HOW IT DOES IT: Uses dynamic dlopen/dlsym for MediaRemote framework,
     *                 registers notifications, emits JSON lines on stdout,
     *                 and listens on stdin for remote playback commands.
     * WHY IT DOES IT: Guarantees full MediaRemote permissions on all macOS versions.
     * -------------------------------------------------------------------------
     */
    private static let helperScriptSource: String = """
    import Foundation
    import AppKit

    typealias MRGetNowPlayingInfoBlock = @convention(block) (NSDictionary?) -> Void
    typealias MRGetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping MRGetNowPlayingInfoBlock) -> Void
    typealias MRGetPIDBlock = @convention(block) (Int32) -> Void
    typealias MRGetPIDFn = @convention(c) (DispatchQueue, @escaping MRGetPIDBlock) -> Void
    typealias MRRegisterNotificationsFn = @convention(c) (DispatchQueue) -> Void
    typealias MRSendCommandFn = @convention(c) (Int32, AnyObject?) -> Bool

    guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW) else {
        exit(1)
    }

    let regFn = unsafeBitCast(dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications")!, to: MRRegisterNotificationsFn.self)
    let getFn = unsafeBitCast(dlsym(handle, "MRMediaRemoteGetNowPlayingInfo")!, to: MRGetNowPlayingInfoFn.self)
    let sendFn = unsafeBitCast(dlsym(handle, "MRMediaRemoteSendCommand")!, to: MRSendCommandFn.self)

    var pidFn: MRGetPIDFn?
    if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationPID") {
        pidFn = unsafeBitCast(sym, to: MRGetPIDFn.self)
    }

    regFn(DispatchQueue.main)

    func query() {
        if let pidFn = pidFn {
            pidFn(DispatchQueue.main) { pid in
                let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Mac Media"
                fetchInfo(appName: appName)
            }
        } else {
            fetchInfo(appName: "Mac Media")
        }
    }

    func fetchInfo(appName: String) {
        getFn(DispatchQueue.main) { dict in
            guard let d = dict as? [String: Any] else {
                let json = "{\\"hasMedia\\":false}\\n"
                FileHandle.standardOutput.write(json.data(using: .utf8)!)
                return
            }
            let title = (d["kMRMediaRemoteNowPlayingInfoTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let artist = (d["kMRMediaRemoteNowPlayingInfoArtist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let album = (d["kMRMediaRemoteNowPlayingInfoAlbum"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rate = (d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double) ?? 0.0
            let dur = (d["kMRMediaRemoteNowPlayingInfoDuration"] as? Double) ?? 0.0
            let elapsed = (d["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double) ?? 0.0

            let payload: [String: Any] = [
                "hasMedia": !title.isEmpty,
                "title": title,
                "artist": artist,
                "album": album,
                "isPlaying": rate > 0.0,
                "duration": dur,
                "elapsedTime": elapsed,
                "appName": appName
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload),
               var str = String(data: data, encoding: .utf8) {
                str += "\\n"
                FileHandle.standardOutput.write(str.data(using: .utf8)!)
            }
        }
    }

    NotificationCenter.default.addObserver(forName: NSNotification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"), object: nil, queue: .main) { _ in
        query()
    }
    NotificationCenter.default.addObserver(forName: NSNotification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"), object: nil, queue: .main) { _ in
        query()
    }

    // Background thread reading commands from stdin
    DispatchQueue.global(qos: .userInitiated).async {
        let input = FileHandle.standardInput
        while true {
            let data = input.availableData
            if data.isEmpty { break }
            if let str = String(data: data, encoding: .utf8) {
                let lines = str.components(separatedBy: .newlines)
                for line in lines {
                    let cmd = line.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    if cmd.isEmpty { continue }
                    DispatchQueue.main.async {
                        switch cmd {
                        case "TOGGLE_PLAY_PAUSE":
                            _ = sendFn(2, nil)
                        case "PLAY":
                            _ = sendFn(0, nil)
                        case "PAUSE":
                            _ = sendFn(1, nil)
                        case "NEXT_TRACK":
                            _ = sendFn(4, nil)
                        case "PREV_TRACK":
                            _ = sendFn(5, nil)
                        case "QUERY":
                            query()
                        default:
                            break
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { query() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { query() }
                    }
                }
            }
        }
    }

    // 1.5-second watchdog timer
    let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
        query()
    }
    RunLoop.main.add(timer, forMode: .common)

    query()
    RunLoop.main.run()
    """

    /**
     * -------------------------------------------------------------------------
     * startMonitoring: Launches Helper Daemon and Streams Metadata
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Writes helper script to Application Support and launches `/usr/bin/swift`.
     * HOW IT DOES IT: Creates stdin/stdout pipes, attaches readability handler for JSON lines.
     * WHY IT DOES IT: Enables reliable, low-latency Now Playing monitoring without permissions blocks.
     * -------------------------------------------------------------------------
     */
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        Self.logToFile("startMonitoring called")

        launchHelperProcess()
    }

    public func stopMonitoring() {
        isMonitoring = false
        Self.logToFile("stopMonitoring called")

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdinPipe?.fileHandleForWriting.closeFile()
        helperProcess?.terminate()
        helperProcess = nil
        stdinPipe = nil
        stdoutPipe = nil
    }

    private func getHelperScriptURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LinkMyMac")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let scriptURL = dir.appendingPathComponent("media_bridge.swift")

        // Write script if missing or updated
        if let data = Self.helperScriptSource.data(using: .utf8) {
            try? data.write(to: scriptURL)
        }
        return scriptURL
    }

    private func launchHelperProcess() {
        guard isMonitoring else { return }

        let scriptURL = getHelperScriptURL()
        Self.logToFile("Launching media helper script at \(scriptURL.path)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        proc.arguments = [scriptURL.path]

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.helperProcess = proc

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            guard let str = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.handleHelperOutput(str)
            }
        }

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                guard let self = self, self.isMonitoring else { return }
                Self.logToFile("Media helper process terminated with code \(p.terminationStatus). Restarting in 1.5s...")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if self.isMonitoring {
                    self.launchHelperProcess()
                }
            }
        }

        do {
            try proc.run()
            Self.logToFile("Media helper process started (PID: \(proc.processIdentifier))")
        } catch {
            Self.logToFile("Failed to start media helper process: \(error)")
        }
    }

    /**
     * -------------------------------------------------------------------------
     * handleHelperOutput: Ingests and Parses Streaming JSON Lines from Helper
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Splits incoming chunks by newline, deserializes JSON, and updates state.
     * HOW IT DOES IT: Manages `outputBuffer` to handle partial chunks across readability events.
     * WHY IT DOES IT: Ensures complete, well-formed JSON payloads are processed safely.
     * -------------------------------------------------------------------------
     */
    private func handleHelperOutput(_ text: String) {
        outputBuffer += text
        let lines = outputBuffer.components(separatedBy: "\n")
        if lines.count > 1 {
            outputBuffer = lines.last ?? ""
            for line in lines.dropLast() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                parseNowPlayingJSON(trimmed)
            }
        }
    }

    private func parseNowPlayingJSON(_ jsonStr: String) {
        guard let data = jsonStr.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }

        var newState = NowPlayingState()
        newState.hasMedia = (dict["hasMedia"] as? Bool) ?? false

        if newState.hasMedia {
            newState.title = (dict["title"] as? String) ?? ""
            newState.artist = (dict["artist"] as? String) ?? ""
            newState.album = (dict["album"] as? String) ?? ""
            newState.isPlaying = (dict["isPlaying"] as? Bool) ?? false
            newState.duration = (dict["duration"] as? Double) ?? 0.0
            newState.elapsedTime = (dict["elapsedTime"] as? Double) ?? 0.0
            newState.appName = (dict["appName"] as? String) ?? "Mac Media"
        }

        self.currentState = newState

        // Determine if broadcast is needed
        if newState != lastSentState || !hasSentInitialConnectedState {
            Self.logToFile("State changed: hasMedia=\(newState.hasMedia), title='\(newState.title)', isPlaying=\(newState.isPlaying), app=\(newState.appName)")
            let sent = broadcastState(newState)
            if sent {
                lastSentState = newState
                hasSentInitialConnectedState = true
            }
        }
    }

    public func forceBroadcastCurrentState() {
        Self.logToFile("forceBroadcastCurrentState requested")
        hasSentInitialConnectedState = false

        // Send query to helper
        sendCommandToHelper("QUERY")

        // If we already hold active state, broadcast it immediately
        if currentState.hasMedia {
            let sent = broadcastState(currentState)
            if sent {
                lastSentState = currentState
                hasSentInitialConnectedState = true
            }
        }
    }

    @discardableResult
    private func broadcastState(_ state: NowPlayingState) -> Bool {
        var payload: [String: Any] = [
            "type": "NOW_PLAYING_UPDATE",
            "hasMedia": state.hasMedia
        ]

        if state.hasMedia {
            payload["title"] = state.title
            payload["artist"] = state.artist
            payload["album"] = state.album
            payload["isPlaying"] = state.isPlaying
            payload["duration"] = state.duration
            payload["elapsedTime"] = state.elapsedTime
            payload["appName"] = state.appName
        }

        let success = p2pClient.sendControlJSON(payload)
        Self.logToFile("broadcastState -> sendControlJSON result: \(success)")
        return success
    }

    /**
     * -------------------------------------------------------------------------
     * handleCommand: Executes Remote Media Command from Android
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Performs Play, Pause, Next Track, or Previous Track on Mac.
     * HOW IT DOES IT:
     *   1. Transmits action to helper daemon over stdin pipe (`MRMediaRemoteSendCommand`).
     *   2. Emits system hardware media key (`NX_KEYTYPE_PLAY`, etc.) as an auxiliary fallback.
     *   3. Fast-refreshes state to propagate changes to Android instantly.
     * WHY IT DOES IT: Delivers immediate, tactile control from the phone's notification shade.
     * -------------------------------------------------------------------------
     */
    public func handleCommand(_ action: String) {
        Self.logToFile("handleCommand received from Android: \(action)")
        let upper = action.uppercased()

        // 1. Direct pipe to helper daemon
        sendCommandToHelper(upper)

        // 2. Hardware media key backup
        switch upper {
        case "TOGGLE_PLAY_PAUSE", "PLAY", "PAUSE":
            postSystemMediaKey(16) // NX_KEYTYPE_PLAY
        case "NEXT_TRACK":
            postSystemMediaKey(17) // NX_KEYTYPE_NEXT
        case "PREV_TRACK":
            postSystemMediaKey(18) // NX_KEYTYPE_PREVIOUS
        default:
            break
        }
    }

    private func sendCommandToHelper(_ cmd: String) {
        guard let inPipe = stdinPipe else { return }
        let line = "\(cmd)\n"
        if let data = line.data(using: .utf8) {
            try? inPipe.fileHandleForWriting.write(contentsOf: data)
        }
    }

    /**
     * -------------------------------------------------------------------------
     * postSystemMediaKey: Hardware Media Key Synthesizer Fallback
     * -------------------------------------------------------------------------
     * WHAT IT DOES: Posts synthetic system-defined media key events.
     * HOW IT DOES IT: Constructs `NSEvent.otherEvent(with: .systemDefined)` and
     *                 posts down/up events to `.cghidEventTap`.
     * WHY IT DOES IT: Guarantees media control even for web browsers or custom players.
     * -------------------------------------------------------------------------
     */
    private func postSystemMediaKey(_ key: Int32) {
        func doKey(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | (down ? 0xa00 : 0xb00))
            let ev = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
        doKey(down: true)
        doKey(down: false)
    }
}
