import AppKit
import SwiftUI

// MARK: - Messages

struct MessagesView: View {
    @ObservedObject var phone: PhoneFeatures
    @State private var draft = ""
    @State private var newRecipient = ""

    private var openThread: PhoneFeatures.SmsThread? {
        phone.threads.first { $0.id == phone.openThreadId }
    }

    private var recipient: String {
        openThread?.address ?? newRecipient.trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("Messages").font(.title2.bold())
                    Spacer()
                    Button { phone.startNewMessage() } label: { Image(systemName: "square.and.pencil") }
                        .buttonStyle(.borderless)
                        .help("New message")
                    Button { phone.refreshThreads() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                }
                .padding(14)
                Divider()
                if phone.threads.isEmpty {
                    emptyHint(phone.smsError ?? "No conversations yet")
                } else {
                    List(phone.threads) { thread in
                        Button { phone.open(thread: thread.id) } label: { threadRow(thread) }
                            .buttonStyle(.plain)
                            .listRowBackground(thread.id == phone.openThreadId ? Color.accentColor.opacity(0.15) : Color.clear)
                    }
                    .listStyle(.plain)
                }
            }
            .frame(width: 290)

            Divider()
            conversation
        }
        .onAppear { if phone.threads.isEmpty { phone.refreshThreads() } }
    }

    private func threadRow(_ thread: PhoneFeatures.SmsThread) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(thread.unread ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.title).font(.subheadline.bold()).lineLimit(1)
                    Spacer()
                    Text(thread.date, format: .dateTime.day().month(.abbreviated))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Text(thread.snippet).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Empty list, or why it's empty (e.g. Messages access not allowed on the phone).
    private func emptyHint(_ text: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "message").font(.system(size: 32)).foregroundColor(.secondary)
            Text(text).font(.caption).foregroundColor(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack {
                if let thread = openThread {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(thread.title).font(.headline)
                        if !thread.name.isEmpty {
                            Text(thread.address).font(.caption).foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("To:").foregroundColor(.secondary)
                    TextField("Phone number", text: $newRecipient)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                }
                Spacer()
            }
            .padding(14)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(phone.messages) { bubble($0).id($0.id) }
                    }
                    .padding(16)
                }
                .onChange(of: phone.messages.last?.id) {
                    if let last = phone.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
            }

            if let error = phone.smsError, !phone.threads.isEmpty {
                Text(error).font(.caption).foregroundColor(.red).padding(.horizontal)
            }
            Divider()
            HStack {
                TextField("Text message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(sendDraft)
                Button("Send", action: sendDraft)
                    .buttonStyle(.borderedProminent)
                    .disabled(recipient.isEmpty || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
    }

    private func bubble(_ message: PhoneFeatures.SmsMessage) -> some View {
        HStack {
            if !message.incoming { Spacer(minLength: 60) }
            VStack(alignment: message.incoming ? .leading : .trailing, spacing: 2) {
                Text(message.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14)
                        .fill(message.incoming ? Color.secondary.opacity(0.15) : Color.accentColor))
                    .foregroundColor(message.incoming ? .primary : .white)
                Text(message.date, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            if message.incoming { Spacer(minLength: 60) }
        }
    }

    private func sendDraft() {
        guard !recipient.isEmpty else { return }
        phone.sendSms(to: recipient, body: draft)
        draft = ""
    }
}

// MARK: - Calls

struct CallsView: View {
    @ObservedObject var phone: PhoneFeatures
    @State private var number = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Calls").font(.title2.bold())
                    Text("Answer, decline and dial from your Mac. Call audio stays on the phone: use its speaker or a Bluetooth headset.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button { phone.refreshCalls() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    callCard
                    HStack {
                        TextField("Phone number", text: $number)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { phone.dial(number) }
                        Button { phone.dial(number) } label: { Label("Call", systemImage: "phone.fill") }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .disabled(number.isEmpty)
                    }
                    if let error = phone.callError {
                        Text(error).font(.caption).foregroundColor(.red)
                    }
                    Text("Recent").font(.headline)
                    ForEach(phone.recentCalls) { recentRow($0) }
                }
                .padding(20)
            }
        }
        .onAppear { if phone.recentCalls.isEmpty { phone.refreshCalls() } }
    }

    @ViewBuilder private var callCard: some View {
        switch phone.callState {
        case .idle:
            EmptyView()
        case .ringing(let caller):
            HStack {
                VStack(alignment: .leading) {
                    Text("Incoming call").font(.caption).foregroundColor(.secondary)
                    Text(caller).font(.title3.bold())
                }
                Spacer()
                Button(action: phone.decline) { Label("Decline", systemImage: "phone.down.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                Button(action: phone.answer) { Label("Answer", systemImage: "phone.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.12)))
        case .active(let caller):
            HStack {
                VStack(alignment: .leading) {
                    Text("On a call (audio on the phone)").font(.caption).foregroundColor(.secondary)
                    Text(caller.isEmpty ? "Call in progress" : caller).font(.title3.bold())
                }
                Spacer()
                Button(action: phone.endCall) { Label("End", systemImage: "phone.down.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.1)))
        }
    }

    private func recentRow(_ call: PhoneFeatures.RecentCall) -> some View {
        HStack(spacing: 12) {
            Image(systemName: call.kind == "outgoing" ? "phone.arrow.up.right" : call.kind == "missed" ? "phone.arrow.down.left.fill" : "phone.arrow.down.left")
                .foregroundColor(call.kind == "missed" || call.kind == "declined" ? .red : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.title).font(.subheadline.bold()).foregroundColor(call.kind == "missed" ? .red : .primary)
                Text("\(call.date.formatted(date: .abbreviated, time: .shortened))\(call.durationSec > 0 ? " • \(Duration.seconds(call.durationSec).formatted(.time(pattern: .minuteSecond)))" : "")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if !call.number.isEmpty {
                Button { phone.dial(call.number) } label: { Image(systemName: "phone.fill") }
                    .buttonStyle(.borderless)
                    .help("Call back")
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Phone screen (mirroring + mouse/keyboard control)

struct PhoneScreenView: View {
    @ObservedObject var phone: PhoneFeatures

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Phone Screen").font(.title2.bold())
                    Text("Click to tap, drag to swipe, scroll to scroll, and type to enter text. Esc is Back.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if phone.isMirroring || phone.mirrorRequested {
                    Button(action: phone.stopMirroring) { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.bordered)
                } else {
                    Button(action: phone.startMirroring) { Label("Start Mirroring", systemImage: "play.rectangle.fill") }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()

            ZStack {
                Color.black
                if let frame = phone.screenFrame {
                    Image(nsImage: frame)
                        .resizable()
                        .scaledToFit()
                        .overlay(PhoneInputSurface(imageSize: frame.size, phone: phone))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "iphone.gen3").font(.system(size: 40)).foregroundColor(.gray)
                        Text(phone.mirrorRequested ? "Approve “Start now” on your phone…" : "Start mirroring to see your phone here.")
                            .foregroundColor(.gray)
                    }
                }
            }

            HStack(spacing: 14) {
                Button { phone.global("back") } label: { Label("Back", systemImage: "chevron.backward") }
                Button { phone.global("home") } label: { Label("Home", systemImage: "circle") }
                Button { phone.global("recents") } label: { Label("Recents", systemImage: "square.on.square") }
                Button { phone.global("notifications") } label: { Label("Notifications", systemImage: "bell") }
                Spacer()
                if let error = phone.mirrorError {
                    Text(error).font(.caption).foregroundColor(.red)
                } else if phone.controlEnabled == false {
                    Text("To control the phone, turn on “LinkMyMac Mac Control” in the phone's Accessibility settings.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(12)
        }
    }
}

/// AppKit input layer over the mirrored frame.
struct PhoneInputSurface: NSViewRepresentable {
    let imageSize: CGSize
    let phone: PhoneFeatures

    func makeNSView(context: Context) -> PhoneInputNSView {
        PhoneInputNSView()
    }

    func updateNSView(_ view: PhoneInputNSView, context: Context) {
        view.imageSize = imageSize
        view.phone = phone
    }
}

final class PhoneInputNSView: NSView {
    var imageSize: CGSize = .zero
    weak var phone: PhoneFeatures?
    private var downAt: CGPoint?
    private var downTime: TimeInterval = 0
    private var scrollAccumulated: CGFloat = 0
    private var lastScrollSent: TimeInterval = 0

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true } // top-left origin, like the phone

    /// Where the aspect-fit frame sits inside this view (same math as SwiftUI .scaledToFit).
    private var imageRect: CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func normalized(_ event: NSEvent) -> CGPoint? {
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        guard rect.width > 0, rect.contains(point) else { return nil }
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self) // so typing goes to the phone
        downAt = normalized(event)
        downTime = event.timestamp
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = downAt else { return }
        downAt = nil
        let end = normalized(event) ?? start
        let heldMs = Int((event.timestamp - downTime) * 1000)
        let rect = imageRect
        let moved = hypot((end.x - start.x) * rect.width, (end.y - start.y) * rect.height)
        if moved < 6 {
            phone?.tap(start, durationMs: heldMs > 500 ? heldMs : 60) // held = long press
        } else {
            phone?.swipe(from: start, to: end, durationMs: max(120, min(heldMs, 1500)))
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let at = normalized(event) else { return }
        // Trackpads report points, mouse wheels report lines.
        scrollAccumulated += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12
        guard abs(scrollAccumulated) > 30, event.timestamp - lastScrollSent > 0.15 else { return }
        let distance = max(-0.35, min(0.35, scrollAccumulated / max(imageRect.height, 1)))
        phone?.swipe(from: at, to: CGPoint(x: at.x, y: max(0, min(1, at.y + distance))), durationMs: 150)
        scrollAccumulated = 0
        lastScrollSent = event.timestamp
    }

    override func keyDown(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command) else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 51: phone?.key("backspace")
        case 36, 76: phone?.key("enter")
        case 53: phone?.global("back") // Esc
        default:
            if let chars = event.characters, !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
                phone?.type(chars)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

// MARK: - Sidebar pieces

/// Phone network + hotspot button for the sidebar device card.
struct PhoneStatusRow: View {
    @ObservedObject var phone: PhoneFeatures

    var body: some View {
        HStack(spacing: 6) {
            if !phone.network.isEmpty {
                Text(phone.network).font(.caption2.bold())
            }
            if phone.signalLevel >= 0 {
                Image(systemName: "cellularbars", variableValue: Double(phone.signalLevel) / 4)
                    .font(.caption2)
            }
            Spacer()
            Button(action: phone.requestHotspot) {
                Label(phone.hotspotPrompted ? "Tap the prompt on your phone" : "Hotspot", systemImage: "personalhotspot")
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .help("Android doesn't let apps switch tethering on, so this puts a one-tap shortcut to Hotspot settings on the phone")
        }
    }
}

/// Live sidebar badges for Messages, Calls and Phone Screen.
struct PhoneTabBadge: View {
    @ObservedObject var phone: PhoneFeatures
    let tab: DashboardTab

    var body: some View {
        switch tab {
        case .messages:
            let unread = phone.threads.filter(\.unread).count
            if unread > 0 { capsule("\(unread)", .green) }
        case .calls:
            if case .ringing = phone.callState { capsule("RINGING", .green) }
            else if case .active = phone.callState { capsule("ON CALL", .red) }
        case .phoneScreen:
            if phone.isMirroring { capsule("LIVE", .red) }
        default:
            EmptyView()
        }
    }

    private func capsule(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color))
    }
}
