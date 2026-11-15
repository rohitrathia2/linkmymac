import AppKit
import Foundation

/**
 * Phone features reached over the paired connection: SMS, calls, screen mirroring with
 * mouse/keyboard control, and the hotspot prompt. MacP2PClient routes their frames here;
 * every send goes through its paired-only sendControlJSON. Protocol: WIRE_SPEC.md §4c.
 */
@MainActor
final class PhoneFeatures: ObservableObject {
    struct SmsThread: Identifiable, Equatable {
        let id: Int64
        let address: String
        let name: String
        let snippet: String
        let date: Date
        let unread: Bool
        var title: String { name.isEmpty ? address : name }
    }

    struct SmsMessage: Identifiable, Equatable {
        let id: Int64
        let body: String
        let date: Date
        let incoming: Bool
    }

    struct RecentCall: Identifiable {
        let id = UUID()
        let number: String
        let name: String
        let kind: String // incoming | outgoing | missed | declined | other
        let date: Date
        let durationSec: Int
        var title: String { name.isEmpty ? number : name }
    }

    enum CallState: Equatable {
        case idle
        case ringing(caller: String)
        case active(caller: String)

        var caller: String? {
            switch self {
            case .idle: return nil
            case .ringing(let caller), .active(let caller): return caller
            }
        }
    }

    // SMS
    @Published private(set) var threads: [SmsThread] = []
    @Published private(set) var messages: [SmsMessage] = []
    @Published private(set) var openThreadId: Int64?
    @Published private(set) var smsError: String?
    // Calls (audio stays on the phone)
    @Published private(set) var callState: CallState = .idle
    @Published private(set) var recentCalls: [RecentCall] = []
    @Published private(set) var callError: String?
    // Screen mirroring + mouse/keyboard control
    @Published private(set) var screenFrame: NSImage?
    @Published private(set) var isMirroring = false
    @Published private(set) var mirrorRequested = false
    @Published private(set) var mirrorError: String?
    @Published private(set) var controlEnabled: Bool? // nil until the phone says
    // Phone network, for the hotspot button
    @Published private(set) var network = ""
    @Published private(set) var signalLevel = -1
    @Published private(set) var hotspotPrompted = false

    weak var client: MacP2PClient?
    /// Incoming-call banner: a caller while ringing, nil once it stops ringing.
    var onRingingChanged: ((String?) -> Void)?

    private func send(_ dict: [String: Any]) {
        client?.sendControlJSON(dict)
    }

    /// First load after pairing.
    func loadAll() {
        refreshThreads()
        refreshCalls()
    }

    func connectionLost() {
        isMirroring = false
        mirrorRequested = false
        screenFrame = nil
        if callState != .idle { onRingingChanged?(nil) }
        callState = .idle
    }

    // MARK: SMS

    func refreshThreads() {
        send(["type": "SMS_THREADS_REQUEST", "limit": 60])
    }

    func open(thread id: Int64) {
        openThreadId = id
        messages = []
        send(["type": "SMS_MESSAGES_REQUEST", "threadId": id, "limit": 200])
    }

    func startNewMessage() {
        openThreadId = nil
        messages = []
    }

    func sendSms(to address: String, body: String) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !text.isEmpty else { return }
        smsError = nil
        send(["type": "SMS_SEND", "requestId": UUID().uuidString, "address": address, "body": text])
    }

    // MARK: Calls

    func answer() { send(["type": "CALL_ACTION", "action": "answer"]) }
    func decline() { send(["type": "CALL_ACTION", "action": "decline"]) }
    func endCall() { send(["type": "CALL_ACTION", "action": "end"]) }

    func dial(_ number: String) {
        let digits = number.filter { "0123456789+*#".contains($0) }
        guard !digits.isEmpty else { return }
        callError = nil
        send(["type": "CALL_DIAL", "number": digits])
    }

    func refreshCalls() {
        send(["type": "CALL_LOG_REQUEST", "limit": 100])
    }

    // MARK: Screen mirroring + control (positions are 0..1 of the phone screen)

    func startMirroring() {
        mirrorError = nil
        mirrorRequested = true
        send(["type": "MIRROR_START"])
    }

    func stopMirroring() {
        mirrorRequested = false
        send(["type": "MIRROR_STOP"])
    }

    func tap(_ point: CGPoint, durationMs: Int = 60) {
        send(["type": "INPUT_TAP", "x": Double(point.x), "y": Double(point.y), "durationMs": durationMs])
    }

    func swipe(from start: CGPoint, to end: CGPoint, durationMs: Int) {
        send(["type": "INPUT_SWIPE", "x1": Double(start.x), "y1": Double(start.y),
              "x2": Double(end.x), "y2": Double(end.y), "durationMs": durationMs])
    }

    func type(_ text: String) { send(["type": "INPUT_TEXT", "text": text]) }
    func key(_ key: String) { send(["type": "INPUT_KEY", "key": key]) }
    func global(_ action: String) { send(["type": "INPUT_GLOBAL", "action": action]) }

    // MARK: Hotspot

    func requestHotspot() {
        hotspotPrompted = false
        send(["type": "HOTSPOT_REQUEST"])
    }

    func updateNetwork(_ json: [String: Any]) {
        network = json["network"] as? String ?? ""
        signalLevel = json["signalLevel"] as? Int ?? -1
    }

    // MARK: Incoming frames

    /// Returns false for frames that aren't phone features.
    func handle(_ type: String, _ json: [String: Any]) -> Bool {
        switch type {
        case "SMS_THREADS":
            smsError = json["error"] as? String
            threads = (json["threads"] as? [[String: Any]] ?? []).map {
                SmsThread(id: Self.int64($0["threadId"]), address: $0["address"] as? String ?? "",
                          name: $0["name"] as? String ?? "", snippet: $0["snippet"] as? String ?? "",
                          date: Self.date($0["dateMs"]), unread: $0["unread"] as? Bool ?? false)
            }

        case "SMS_MESSAGES":
            guard Self.int64(json["threadId"]) == openThreadId else { return true } // a thread we left
            if let error = json["error"] as? String { smsError = error }
            messages = (json["messages"] as? [[String: Any]] ?? []).map {
                SmsMessage(id: Self.int64($0["id"]), body: $0["body"] as? String ?? "",
                           date: Self.date($0["dateMs"]), incoming: $0["incoming"] as? Bool ?? true)
            }

        case "SMS_SEND_RESULT":
            if json["ok"] as? Bool != true {
                smsError = json["error"] as? String ?? "Couldn't send the message"
            }

        case "SMS_UPDATED": // something arrived, was sent or was read on the phone
            refreshThreads()
            if let id = openThreadId {
                send(["type": "SMS_MESSAGES_REQUEST", "threadId": id, "limit": 200])
            }

        case "CALL_STATE":
            let name = json["name"] as? String ?? ""
            let caller = name.isEmpty ? json["number"] as? String ?? "" : name
            switch json["state"] as? String {
            case "ringing":
                callState = .ringing(caller: caller.isEmpty ? "Unknown caller" : caller)
                onRingingChanged?(callState.caller)
            case "active":
                callState = .active(caller: caller.isEmpty ? callState.caller ?? "" : caller)
                onRingingChanged?(nil)
            default:
                callState = .idle
                onRingingChanged?(nil)
                refreshCalls()
            }

        case "CALL_ACTION_RESULT":
            callError = json["ok"] as? Bool == true ? nil : json["error"] as? String

        case "CALL_LOG":
            callError = json["error"] as? String
            recentCalls = (json["calls"] as? [[String: Any]] ?? []).map {
                RecentCall(number: $0["number"] as? String ?? "", name: $0["name"] as? String ?? "",
                           kind: $0["kind"] as? String ?? "other", date: Self.date($0["dateMs"]),
                           durationSec: ($0["durationSec"] as? NSNumber)?.intValue ?? 0)
            }

        case "MIRROR_STATUS":
            isMirroring = json["active"] as? Bool ?? false
            if !isMirroring {
                screenFrame = nil
                mirrorRequested = false
            }
            mirrorError = json["error"] as? String
            if let enabled = json["controlEnabled"] as? Bool { controlEnabled = enabled }

        case "MIRROR_FRAME":
            if let image = (json["jpegBase64"] as? String).flatMap({ Data(base64Encoded: $0) }).flatMap(NSImage.init(data:)) {
                screenFrame = image
                isMirroring = true
            }

        case "CONTROL_STATUS":
            controlEnabled = json["enabled"] as? Bool

        case "HOTSPOT_RESULT":
            hotspotPrompted = json["prompted"] as? Bool ?? false

        default:
            return false
        }
        return true
    }

    private static func int64(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? 0 }

    private static func date(_ value: Any?) -> Date {
        Date(timeIntervalSince1970: Double((value as? NSNumber)?.int64Value ?? 0) / 1000)
    }
}

#if DEBUG
extension PhoneFeatures {
    /// Sample threads, calls and a mirrored screen for design checks (see MacP2PClient.loadPreviewData).
    func loadPreviewData() {
        let now = Date()
        threads = [
            SmsThread(id: 1, address: "+1 (415) 555-0132", name: "Alex Chen", snippet: "Running 10 min late, sorry!", date: now.addingTimeInterval(-120), unread: false),
            SmsThread(id: 2, address: "+1 (415) 555-0101", name: "Mom", snippet: "Did you eat? Call when you can.", date: now.addingTimeInterval(-5_400), unread: true),
            SmsThread(id: 3, address: "+1 (415) 555-0188", name: "Priya Sharma", snippet: "Sent the slides, take a look", date: now.addingTimeInterval(-12_000), unread: true),
            SmsThread(id: 4, address: "AX-PARCEL", name: "", snippet: "Your parcel is out for delivery today.", date: now.addingTimeInterval(-20_000), unread: false),
            SmsThread(id: 5, address: "+1 (415) 555-0123", name: "Dad", snippet: "Call me when you are free", date: now.addingTimeInterval(-90_000), unread: false),
            SmsThread(id: 6, address: "+1 (415) 555-0177", name: "Jordan Lee", snippet: "Haha yes, see you Saturday", date: now.addingTimeInterval(-260_000), unread: false),
        ]
        openThreadId = 1
        messages = [
            SmsMessage(id: 1, body: "Are we still on for dinner tonight?", date: now.addingTimeInterval(-1_800), incoming: true),
            SmsMessage(id: 2, body: "Yes! I booked a table at the place near the station.", date: now.addingTimeInterval(-1_700), incoming: false),
            SmsMessage(id: 3, body: "Perfect. What time?", date: now.addingTimeInterval(-1_600), incoming: true),
            SmsMessage(id: 4, body: "7:30. I'll grab us a table if I'm early.", date: now.addingTimeInterval(-1_500), incoming: false),
            SmsMessage(id: 5, body: "Running 10 min late, sorry!", date: now.addingTimeInterval(-120), incoming: true),
        ]
        callState = .ringing(caller: "Priya Sharma")
        recentCalls = [
            RecentCall(number: "+1 (415) 555-0188", name: "Priya Sharma", kind: "missed", date: now.addingTimeInterval(-3_600), durationSec: 0),
            RecentCall(number: "+1 (415) 555-0101", name: "Mom", kind: "incoming", date: now.addingTimeInterval(-7_200), durationSec: 724),
            RecentCall(number: "+1 (415) 555-0132", name: "", kind: "outgoing", date: now.addingTimeInterval(-90_000), durationSec: 151),
            RecentCall(number: "+1 (415) 555-0132", name: "Alex Chen", kind: "outgoing", date: now.addingTimeInterval(-100_000), durationSec: 48),
            RecentCall(number: "", name: "Unknown number", kind: "declined", date: now.addingTimeInterval(-300_000), durationSec: 0),
            RecentCall(number: "+1 (415) 555-0123", name: "Dad", kind: "incoming", date: now.addingTimeInterval(-400_000), durationSec: 322),
        ]
        network = "5G"
        signalLevel = 4
        controlEnabled = true
        isMirroring = true
        screenFrame = PreviewArt.thumbnail(3, width: 360, height: 800).flatMap { NSImage(data: $0) }
    }
}
#endif
