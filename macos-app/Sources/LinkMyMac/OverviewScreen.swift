import SwiftUI
import AppKit

/// Home screen once a phone is connected (Figma: Mac · Connected): device hero, feature
/// shortcuts, recent notifications and quick actions.
struct OverviewScreen: View {
    @ObservedObject var client: MacP2PClient
    @ObservedObject var phone: PhoneFeatures
    let open: (DashboardTab) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                Text("Your phone, on your Mac").font(.lmTitle).tracking(-0.1).foregroundStyle(Theme.textPrimary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), spacing: 16) {
                    tiles
                }
                HStack(alignment: .top, spacing: 16) {
                    recent
                    quickActions.frame(width: 300)
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 24)
        }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 18) {
            Image(systemName: "iphone").font(.system(size: 24, weight: .medium)).foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.white.opacity(0.18)))
            VStack(alignment: .leading, spacing: 4) {
                Text(client.connectedDeviceName ?? "Your phone").font(.lmLargeTitle).tracking(-0.4).foregroundStyle(.white)
                Text(client.isWirelessConnection ? "Connected over Wi‑Fi" : "Connected over USB · \(client.directEndpointLabel)")
                    .font(.lmBody).foregroundStyle(.white.opacity(0.82))
            }
            Spacer(minLength: 12)
            HStack(spacing: 28) {
                stat(client.remoteBatteryPercent.map { "\($0)%" } ?? "—", "Battery")
                stat(phone.network.isEmpty ? "—" : phone.network, "Network")
                stat(phone.signalLevel >= 0 ? "\(phone.signalLevel)/4" : "—", "Signal")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color(red: 0.31, green: 0.36, blue: 1).opacity(0.25), radius: 12, y: 10)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.lmLargeTitle).tracking(-0.4).foregroundStyle(.white)
            Text(label).font(.lmCaption).foregroundStyle(.white.opacity(0.75))
        }
    }

    // MARK: Feature tiles

    @ViewBuilder private var tiles: some View {
        FeatureTile(symbol: "bell", title: "Notifications",
                    detail: client.notifications.isEmpty ? "Mirrored live" : "\(client.notifications.count) new · mirrored live") { open(.notifications) }
        FeatureTile(symbol: "photo", title: "Photos", detail: total(.photos, "photo")) { open(.photos) }
        FeatureTile(symbol: "video", title: "Videos", detail: total(.videos, "video")) { open(.videos) }
        FeatureTile(symbol: "folder", title: "Files",
                    detail: activeTransfers > 0 ? "\(activeTransfers) sending" : "Drop files here to send") { open(.files) }
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                if !files.isEmpty { client.sendFiles(files) }
                return !files.isEmpty
            }
        FeatureTile(symbol: "message", title: "Messages",
                    detail: phone.threads.isEmpty ? "Text from your Mac" : "\(phone.threads.count) conversations") { open(.messages) }
        FeatureTile(symbol: "phone", title: "Calls", detail: "Answer and dial from here") { open(.calls) }
        FeatureTile(symbol: "iphone", title: "Phone Screen", detail: phone.isMirroring ? "Mirroring now" : "Mirror it, control it") { open(.phoneScreen) }
        FeatureTile(symbol: "camera", title: "Camera", detail: client.isCameraStreaming ? "Live now" : "Live view, floating window") { open(.camera) }
    }

    private var activeTransfers: Int { client.transfers.filter { $0.status == .inProgress }.count }

    private func total(_ kind: MediaKind, _ noun: String) -> String {
        guard let n = client.mediaTotals[kind] else { return "Browse your \(noun)s" }
        return "\(n.formatted()) \(noun)\(n == 1 ? "" : "s")"
    }

    // MARK: Recent activity & quick actions

    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent activity").font(.lmHeadline).foregroundStyle(Theme.textPrimary)
            if client.notifications.isEmpty {
                Text("New notifications from your phone show up here.").font(.lmCallout).foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(client.notifications.prefix(3)) { n in
                    Button { open(.notifications) } label: {
                        HStack(spacing: 12) {
                            NotificationAppIcon(data: n.appIconData, size: 28)
                            Text(n.appName).font(.lmHeadline).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Text(n.title).font(.lmBody).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Date(timeIntervalSince1970: TimeInterval(n.postTimeMs) / 1000)
                                    .formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                                .font(.lmCaption).foregroundStyle(Theme.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lmCard(padding: 18)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick actions").font(.lmHeadline).foregroundStyle(Theme.textPrimary)
            action("personalhotspot", "Turn on hotspot") { phone.requestHotspot() }
            action("doc.on.clipboard", "Send clipboard") {
                if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty { client.sendClipboardText(text) }
            }
            action("paperplane", "Send a file") { chooseFilesAndSend(to: client) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lmCard(padding: 18)
    }

    private func action(_ symbol: String, _ title: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, size: 28, radius: 8, iconSize: 13, background: Theme.surfaceMuted, foreground: Theme.textSecondary)
                Text(title).font(.lmBody).foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The Android app's own icon when the phone sent one, else a neutral bell tile.
struct NotificationAppIcon: View {
    let data: Data?
    var size: CGFloat = 36
    var body: some View {
        if let data, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
        } else {
            IconTile(symbol: "bell", size: size, radius: size * 0.26, iconSize: size * 0.45)
        }
    }
}
