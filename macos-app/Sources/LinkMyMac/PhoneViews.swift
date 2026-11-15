import AppKit
import SwiftUI

// MARK: - Shared pieces

/// Contact initials on a tinted circle; the tint is stable per name (Figma Mac/Avatar).
struct ContactAvatar: View {
    let name: String
    var size: CGFloat = 36
    private static let palette: [(UInt32, UInt32)] = [
        (0xDCE7FF, 0x2346B8), (0xFCE1EE, 0xA3175B), (0xEAE0FF, 0x5B2BB5), (0xFFEBC7, 0x8F5400),
        (0xD4F4E2, 0x0B7A3B), (0xD2F3EF, 0x0B6E66), (0xE6E8F0, 0x4A5068),
    ]
    var body: some View {
        let (bg, fg) = Self.palette[name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % Self.palette.count]
        Text(initials)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(Self.color(fg))
            .frame(width: size, height: size)
            .background(Circle().fill(Self.color(bg)))
    }
    private var initials: String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        guard !words.isEmpty else { return "#" }
        return words.prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// "7:42 PM" today, "Yesterday", weekday this week, else "12 Nov".
func shortDate(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 { return date.formatted(.dateTime.weekday(.abbreviated)) }
    return date.formatted(.dateTime.day().month(.abbreviated))
}

// MARK: - Messages (Figma: Mac · Messages)

struct MessagesView: View {
    @ObservedObject var phone: PhoneFeatures
    @State private var draft = ""
    @State private var newRecipient = ""
    @State private var search = ""

    private var openThread: PhoneFeatures.SmsThread? {
        phone.threads.first { $0.id == phone.openThreadId }
    }

    private var recipient: String {
        openThread?.address ?? newRecipient.trimmingCharacters(in: .whitespaces)
    }

    private var visibleThreads: [PhoneFeatures.SmsThread] {
        guard !search.isEmpty else { return phone.threads }
        let q = search.lowercased()
        return phone.threads.filter { $0.title.lowercased().contains(q) || $0.snippet.lowercased().contains(q) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 8) {
                LMSearchField(placeholder: "Search messages", text: $search, width: nil)
                if phone.threads.isEmpty {
                    EmptyStateView(symbol: "message", title: "No conversations", message: phone.smsError ?? "Texts on your phone show up here.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(visibleThreads) { thread in
                                Button { phone.open(thread: thread.id) } label: { threadRow(thread, selected: thread.id == phone.openThreadId) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(width: 320)
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.borderSubtle).frame(width: 1) }

            conversation
                .background(Theme.surface)
        }
        .navigationTitle("Messages")
        .navigationSubtitle("Texts from your phone")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                IconButton(symbol: "square.and.pencil", help: "New message") { phone.startNewMessage() }
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { phone.refreshThreads() }
            }
        }
        .onAppear { if phone.threads.isEmpty { phone.refreshThreads() } }
    }

    private func threadRow(_ thread: PhoneFeatures.SmsThread, selected: Bool) -> some View {
        HStack(spacing: 10) {
            ContactAvatar(name: thread.title)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(thread.title).font(.lmHeadline).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(shortDate(thread.date)).font(.lmCaption).foregroundStyle(Theme.textTertiary)
                }
                Text(thread.snippet).font(.lmCallout).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            if thread.unread {
                Circle().fill(Theme.brand).frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Theme.brandSoft : .clear))
        .contentShape(Rectangle())
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let thread = openThread {
                    ContactAvatar(name: thread.title)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(thread.title).font(.lmHeadline).foregroundStyle(Theme.textPrimary)
                        if !thread.name.isEmpty {
                            Text(thread.address).font(.lmCallout).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    IconButton(symbol: "phone", help: "Call \(thread.title) from your phone") { phone.dial(thread.address) }
                } else {
                    Text("To:").font(.lmBody).foregroundStyle(Theme.textSecondary)
                    TextField("Phone number", text: $newRecipient).textFieldStyle(LMTextFieldStyle()).frame(maxWidth: 260)
                    Spacer()
                }
            }
            .padding(.leading, 20).padding(.trailing, 14)
            .frame(height: 60)
            Hairline()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(phone.messages.enumerated()), id: \.element.id) { index, message in
                            if index == 0 || !Calendar.current.isDate(message.date, inSameDayAs: phone.messages[index - 1].date) {
                                Text(message.date.formatted(.dateTime.weekday(.wide).day().month().hour().minute()))
                                    .font(.lmCaption).foregroundStyle(Theme.textTertiary)
                                    .padding(.vertical, 6)
                            }
                            bubble(message).id(message.id)
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 20)
                }
                .onChange(of: phone.messages.last?.id) {
                    if let last = phone.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
            }

            if let error = phone.smsError, !phone.threads.isEmpty {
                Text(error).font(.lmCallout).foregroundStyle(Theme.danger).padding(.horizontal, 20).padding(.bottom, 8)
            }
            Hairline()
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    TextField("Text message", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain).font(.lmBody).lineLimit(1...4)
                        .onSubmit(sendDraft)
                    Text("SMS").font(.lmCaption).foregroundStyle(Theme.textTertiary)
                }
                .padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surfaceMuted))
                Button(action: sendDraft) {
                    Image(systemName: "paperplane.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.onBrand)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.brand))
                }
                .buttonStyle(.plain)
                .disabled(cannotSend)
                .opacity(cannotSend ? 0.45 : 1)
                .help("Send")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private var cannotSend: Bool {
        recipient.isEmpty || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func bubble(_ message: PhoneFeatures.SmsMessage) -> some View {
        HStack {
            if !message.incoming { Spacer(minLength: 80) }
            Text(message.body)
                .font(.lmBody)
                .textSelection(.enabled)
                .foregroundStyle(message.incoming ? Theme.textPrimary : Theme.onBrand)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(message.incoming ? Theme.surfaceMuted : Theme.brand))
                .frame(maxWidth: 380, alignment: message.incoming ? .leading : .trailing)
                .help(message.date.formatted(date: .abbreviated, time: .shortened))
            if message.incoming { Spacer(minLength: 80) }
        }
    }

    private func sendDraft() {
        guard !cannotSend else { return }
        phone.sendSms(to: recipient, body: draft)
        draft = ""
    }
}

// MARK: - Calls (Figma: Mac · Calls)

struct CallsView: View {
    @ObservedObject var phone: PhoneFeatures
    @State private var number = ""

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    callCard
                    HStack(spacing: 6) {
                        Image(systemName: "iphone").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                        Text("Answering here picks up on your phone. Call audio stays on the phone.")
                            .font(.lmCallout).foregroundStyle(Theme.textTertiary)
                    }
                    if let error = phone.callError {
                        Text(error).font(.lmCallout).foregroundStyle(Theme.danger)
                    }
                    HStack(spacing: 8) {
                        Text("Recent").font(.lmTitle).tracking(-0.1).foregroundStyle(Theme.textPrimary)
                        if !phone.recentCalls.isEmpty {
                            Text("Last \(phone.recentCalls.count) calls").font(.lmCallout).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .padding(.top, 6)
                    if phone.recentCalls.isEmpty {
                        Text("Calls on your phone show up here.").font(.lmCallout).foregroundStyle(Theme.textSecondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(phone.recentCalls) { recentRow($0) }
                        }
                        .padding(.vertical, 4)
                        .lmCard(padding: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                dialer.frame(width: 300)
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
        }
        .navigationTitle("Calls")
        .navigationSubtitle("Placed and answered by your phone")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                IconButton(symbol: "arrow.clockwise", help: "Refresh") { phone.refreshCalls() }
            }
        }
        .onAppear { if phone.recentCalls.isEmpty { phone.refreshCalls() } }
    }

    @ViewBuilder private var callCard: some View {
        switch phone.callState {
        case .idle:
            EmptyView()
        case .ringing(let caller):
            liveCall(caller: caller, status: "Incoming call · ringing on your phone") {
                roundButton("Decline", symbol: "phone.down.fill", color: Theme.callRed, action: phone.decline)
                roundButton("Answer", symbol: "phone.fill", color: Theme.callGreen, action: phone.answer)
            }
        case .active(let caller):
            liveCall(caller: caller.isEmpty ? "Call in progress" : caller, status: "On a call · audio is on your phone") {
                roundButton("End", symbol: "phone.down.fill", color: Theme.callRed, action: phone.endCall)
            }
        }
    }

    private func liveCall<Buttons: View>(caller: String, status: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 14) {
            Text(String(caller.first(where: \.isLetter) ?? "#").uppercased())
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 48, height: 48).background(Circle().fill(.white.opacity(0.22)))
            VStack(alignment: .leading, spacing: 2) {
                Text(caller).font(.lmLargeTitle).tracking(-0.4).foregroundStyle(.white).lineLimit(1)
                Text(status).font(.lmBody).foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: 8)
            buttons()
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color(red: 0.31, green: 0.36, blue: 1).opacity(0.25), radius: 12, y: 10)
    }

    private func roundButton(_ title: String, symbol: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(Circle().fill(color)).shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                Text(title).font(.lmCaption).foregroundStyle(.white.opacity(0.92))
            }
        }
        .buttonStyle(.plain)
    }

    private func recentRow(_ call: PhoneFeatures.RecentCall) -> some View {
        let missed = call.kind == "missed"
        let symbol: String = {
            switch call.kind {
            case "outgoing": return "phone.arrow.up.right"
            case "missed": return "phone.arrow.down.left"
            case "declined": return "phone.down"
            default: return "phone.arrow.down.left"
            }
        }()
        return HStack(spacing: 12) {
            IconTile(symbol: symbol, size: 32, radius: 9, iconSize: 14,
                     background: missed ? Theme.dangerSoft : Theme.surfaceMuted,
                     foreground: missed ? Theme.danger : call.kind == "declined" ? Theme.textTertiary : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(call.title).font(.lmHeadline).foregroundStyle(missed ? Theme.danger : Theme.textPrimary).lineLimit(1)
                Text("\(call.kind.capitalized) · \(shortDate(call.date))").font(.lmCallout).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if call.durationSec > 0 {
                Text(Duration.seconds(call.durationSec).formatted(.time(pattern: .minuteSecond)))
                    .font(.lmCallout).foregroundStyle(Theme.textTertiary).monospacedDigit()
            }
            if !call.number.isEmpty {
                Button { phone.dial(call.number) } label: {
                    Image(systemName: "phone.fill").font(.system(size: 12)).foregroundStyle(Theme.brand)
                        .frame(width: 28, height: 28).background(Circle().fill(Theme.brandSoft))
                }
                .buttonStyle(.plain)
                .help("Call back")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var dialer: some View {
        VStack(spacing: 14) {
            Text("Dial a number").font(.lmHeadline).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                Color.clear.frame(width: 28, height: 28)
                TextField("Number", text: $number)
                    .textFieldStyle(.plain).font(.lmKeypad).multilineTextAlignment(.center)
                    .onSubmit { if !number.isEmpty { phone.dial(number) } }
                IconButton(symbol: "delete.left", help: "Delete") { if !number.isEmpty { number.removeLast() } }
                    .disabled(number.isEmpty)
            }
            VStack(spacing: 10) {
                ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]], id: \.self) { row in
                    HStack(spacing: 14) {
                        ForEach(row, id: \.self) { digit in
                            KeypadKey(digit: digit, letters: Self.letters[digit] ?? "") { number.append(digit) }
                        }
                    }
                }
            }
            Button { phone.dial(number) } label: {
                Label("Call", systemImage: "phone.fill").font(.lmHeadline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).frame(height: 44)
                    .background(Capsule().fill(Theme.callGreen))
            }
            .buttonStyle(.plain)
            .disabled(number.isEmpty)
            .opacity(number.isEmpty ? 0.5 : 1)
            Text("Your phone places the call.").font(.lmCaption).foregroundStyle(Theme.textTertiary)
        }
        .padding(20)
        .lmCard(padding: 0, radius: 16)
    }

    private static let letters = ["2": "ABC", "3": "DEF", "4": "GHI", "5": "JKL", "6": "MNO", "7": "PQRS", "8": "TUV", "9": "WXYZ", "0": "+"]
}

/// One dial-pad key (Figma Mac/Keypad key).
private struct KeypadKey: View {
    let digit: String
    let letters: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(digit).font(.lmKeypad).foregroundStyle(Theme.textPrimary)
                Text(letters).font(.lmCaption).foregroundStyle(Theme.textTertiary).frame(height: 13)
            }
            .frame(width: 64, height: 52)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceMuted))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Phone screen: mirroring + mouse/keyboard control (Figma: Mac · Phone Screen)

struct PhoneScreenView: View {
    @ObservedObject var phone: PhoneFeatures

    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            mirroredPhone
            controls.frame(width: 360)
        }
        .padding(.horizontal, 32).padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Phone Screen")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if phone.isMirroring {
                    StatusChip(tone: .success, label: "Mirroring")
                    Button("Stop Mirroring", action: phone.stopMirroring).buttonStyle(.lmSecondary)
                } else if phone.mirrorRequested {
                    StatusChip(tone: .warning, label: "Waiting for your OK on the phone")
                    Button("Cancel", action: phone.stopMirroring).buttonStyle(.lmSecondary)
                } else {
                    Button("Start Mirroring", action: phone.startMirroring).buttonStyle(.lmPrimary)
                }
            }
        }
    }

    private var mirroredPhone: some View {
        let ratio = phone.screenFrame.map { ($0.size.width + 16) / ($0.size.height + 16) } ?? 300.0 / 640.0
        return ZStack {
            RoundedRectangle(cornerRadius: 42, style: .continuous).fill(Color(red: 0.04, green: 0.045, blue: 0.07))
            RoundedRectangle(cornerRadius: 42, style: .continuous).strokeBorder(Color(white: 0.2), lineWidth: 2)
            Group {
                if let frame = phone.screenFrame {
                    Image(nsImage: frame)
                        .resizable()
                        .scaledToFit()
                        .overlay(PhoneInputSurface(imageSize: frame.size, phone: phone))
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "iphone").font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.5))
                        Text(phone.mirrorRequested ? "Tap “Start now” on your phone…" : "Start mirroring to see your phone here.")
                            .font(.lmCallout).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                        if !phone.mirrorRequested {
                            Button("Start Mirroring", action: phone.startMirroring).buttonStyle(.lmPrimary).padding(.top, 4)
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .padding(8)
        }
        .aspectRatio(ratio, contentMode: .fit)
        .shadow(color: .black.opacity(0.25), radius: 24, y: 24)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconTile(symbol: "cursorarrow", size: 36, radius: 10, iconSize: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Mac Control").font(.lmHeadline).foregroundStyle(Theme.textPrimary)
                        Text("Use this Mac’s mouse and keyboard on your phone").font(.lmCallout).foregroundStyle(Theme.textSecondary)
                    }
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "keyboard").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    Text("Click to tap, drag to swipe, scroll to scroll, and type to enter text. Esc is Back.")
                        .font(.lmCallout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceMuted))
                switch phone.controlEnabled {
                case true?: StatusChip(tone: .success, label: "Turned on in Accessibility on your phone")
                case false?: StatusChip(tone: .warning, label: "Turn on “LinkMyMac Mac Control” in Accessibility")
                case nil: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lmCard(padding: 18)

            VStack(alignment: .leading, spacing: 12) {
                Text("Phone buttons").font(.lmHeadline).foregroundStyle(Theme.textPrimary)
                HStack(spacing: 10) {
                    toolButton("Back", symbol: "chevron.backward") { phone.global("back") }
                    toolButton("Home", symbol: "circle") { phone.global("home") }
                    toolButton("Recents", symbol: "square.on.square") { phone.global("recents") }
                    toolButton("Alerts", symbol: "bell") { phone.global("notifications") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lmCard(padding: 18)

            VStack(alignment: .leading, spacing: 10) {
                Text("Stream").font(.lmHeadline).foregroundStyle(Theme.textPrimary)
                KeyValueRow(key: "Resolution", value: phone.screenFrame.map { "\(Int($0.size.width)) × \(Int($0.size.height))" } ?? "—")
                KeyValueRow(key: "Format", value: "JPEG frames")
                KeyValueRow(key: "Who can see it", value: "Only this Mac")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lmCard(padding: 18)

            if let error = phone.mirrorError {
                Text(error).font(.lmCallout).foregroundStyle(Theme.danger)
            }
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                Text("Your phone asks for permission each time mirroring starts.").font(.lmCallout).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func toolButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(title).font(.lmCaption).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity).frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceMuted))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
