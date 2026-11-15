import SwiftUI

/// "Pair a phone" (Figma: Mac · Pair a phone). Find the phone on Wi‑Fi, then type the
/// 6-character code it shows. Codes use A–Z and 2–9 without 0, O, 1, I or L.
struct PairingScreen: View {
    @ObservedObject var client: MacP2PClient
    @Binding var code: String
    let submit: () -> Void
    let showQR: () -> Void
    @FocusState private var codeFocused: Bool

    private static let alphabet = Set("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static func clean(_ raw: String) -> String {
        String(raw.uppercased().filter { alphabet.contains($0) }.prefix(6))
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 16) {
                    card
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.shield").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                        Text("Your phone checks the code. After a wrong code, pairing pauses for 3 seconds.")
                            .font(.lmCallout).foregroundStyle(Theme.textTertiary)
                    }
                    HStack(spacing: 6) {
                        Text("Can’t find your phone?").foregroundStyle(Theme.textSecondary)
                        linkButton("Scan its QR code", action: showQR)
                        Text("·").foregroundStyle(Theme.textTertiary)
                        linkButton("Connect with USB") { client.connectDirect(host: "127.0.0.1", port: 8765) }
                    }
                    .font(.lmCallout)
                }
                .padding(.horizontal, 32).padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
        .onAppear { codeFocused = client.needsPairingCode }
        .onChange(of: client.needsPairingCode) { _, needs in codeFocused = needs }
    }

    private var card: some View {
        VStack(spacing: 20) {
            linkVisual
            VStack(spacing: 8) {
                Text("Pair your Android phone").font(.lmLargeTitle).tracking(-0.4).foregroundStyle(Theme.textPrimary)
                Text("Open LinkMyMac on your phone. It shows a 6-character code — type it below. Both devices need to be on the same Wi‑Fi.")
                    .font(.lmBody).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).frame(width: 440)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: client.connectedDeviceName != nil && !client.isWirelessConnection ? "Connected over USB" : "Found on your Wi‑Fi")
                deviceRows
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Type the code from your phone")
                codeRow
                Text("Letters and numbers only — never 0, O, 1, I or L.").font(.lmCallout).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(client.needsPairingCode ? 1 : 0.55)
            HStack(spacing: 12) {
                StatusChip(tone: status.tone, label: status.label)
                Spacer()
                Button("Pair", action: submit)
                    .buttonStyle(LMButtonStyle(kind: .primary, fullWidth: true))
                    .frame(width: 96)
                    .disabled(!client.needsPairingCode || code.count < 6)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 600)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.borderSubtle))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 8)
    }

    private var linkVisual: some View {
        HStack(spacing: 10) {
            IconTile(symbol: "laptopcomputer", size: 56, radius: 16, iconSize: 24)
            dash
            Image(systemName: "lock").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Theme.surface))
                .overlay(Circle().strokeBorder(Theme.borderSubtle))
            dash
            IconTile(symbol: "iphone", size: 56, radius: 16, iconSize: 24)
        }
    }

    private var dash: some View {
        HorizontalLine()
            .stroke(Theme.brand, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))
            .frame(width: 52, height: 2)
    }

    @ViewBuilder private var deviceRows: some View {
        if let name = client.connectedDeviceName, !client.isWirelessConnection {
            PhoneRow(name: name, detail: "USB · \(client.directEndpointLabel)", selected: true) {}
        } else if client.discoveredPeers.isEmpty {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Looking for phones running LinkMyMac on this Wi‑Fi…").font(.lmCallout).foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surfaceMuted))
        } else {
            ForEach(client.discoveredPeers) { peer in
                let selected = client.isWirelessConnection && client.connectedDeviceName != nil
                    && (client.connectedDeviceName == peer.name || client.discoveredPeers.count == 1)
                PhoneRow(name: peer.name, detail: "Wi‑Fi · found nearby", selected: selected) { client.connect(to: peer) }
            }
        }
    }

    private var chars: [Character] { Array(code) }

    private var codeRow: some View {
        ZStack(alignment: .leading) {
            // Invisible field that takes the typing (and ⌘V); the cells below draw the code.
            TextField("", text: Binding(get: { code }, set: { code = Self.clean($0) }))
                .textFieldStyle(.plain)
                .focused($codeFocused)
                .focusEffectDisabled()
                .opacity(0.02)
                .frame(width: 1, height: 1)
                .onSubmit { if code.count == 6 { submit() } }
                .disabled(!client.needsPairingCode)
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { i in
                    if i == 3 { Text("–").font(.lmTitle).foregroundStyle(Theme.textTertiary) }
                    CodeCell(character: i < chars.count ? chars[i] : nil, phase: phase(i))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { codeFocused = true }
        }
    }

    private func phase(_ i: Int) -> CodeCell.Phase {
        if i < chars.count { return .filled }
        return i == chars.count && codeFocused && client.needsPairingCode ? .active : .empty
    }

    private var status: (tone: StatusChip.Tone, label: String) {
        if let error = client.pairingError { return (.danger, error) }
        if client.needsPairingCode { return code.count == 6 ? (.brand, "Ready — press Pair") : (.neutral, "Waiting for code") }
        if client.connectedDeviceName != nil { return (.warning, "Connecting…") }
        if client.discoveredPeers.isEmpty { return (.brand, "Looking for your phone…") }
        return (.neutral, "Pick your phone")
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).foregroundStyle(Theme.brand) }.buttonStyle(.plain)
    }
}

/// A phone found on the network (Figma Mac/Device row: Default / Selected).
private struct PhoneRow: View {
    let name: String
    let detail: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconTile(symbol: "iphone", size: 36, radius: 10, iconSize: 17,
                         background: selected ? Theme.surface : Theme.surfaceMuted,
                         foreground: selected ? Theme.brand : Theme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.lmHeadline).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(.lmCallout).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: selected ? "checkmark" : "chevron.right")
                    .font(.system(size: selected ? 14 : 12, weight: .semibold))
                    .foregroundStyle(selected ? Theme.brand : Theme.textTertiary)
            }
            .padding(.leading, 14).padding(.trailing, 16)
            .frame(height: 64)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.brandSoft : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.brand : Theme.borderSubtle, lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct HorizontalLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}
