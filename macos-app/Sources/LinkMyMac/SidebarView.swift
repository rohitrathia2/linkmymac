import SwiftUI

/// The main sidebar (Figma: Sidebar in the Mac windows): brand, navigation with badges,
/// and the device card. Observes the phone too, so call/mirroring badges stay live.
struct SidebarView: View {
    @ObservedObject var client: MacP2PClient
    @ObservedObject var phone: PhoneFeatures
    @Binding var selection: DashboardTab

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                BrandMark(size: 32)
                VStack(alignment: .leading, spacing: 0) {
                    Text("LinkMyMac").font(.lmTitle).tracking(-0.1).foregroundStyle(Theme.textPrimary)
                    Text("Your Android, on your Mac").font(.lmCaption).tracking(0.1).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 16)

            if client.isPaired {
                row(.overview)
            } else {
                SidebarRow(symbol: "link", label: "Pair a phone", selected: true)
            }
            SectionLabel(text: "Phone").padding(.leading, 10).padding(.top, 14).padding(.bottom, 6)
            ForEach(DashboardTab.allCases.filter { $0 != .overview }) { row($0) }
            Spacer(minLength: 12)
            deviceCard
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }

    private func row(_ tab: DashboardTab) -> some View {
        Button { selection = tab } label: {
            SidebarRow(symbol: tab.iconName, label: tab.rawValue,
                       selected: client.isPaired && selection == tab,
                       disabled: !client.isPaired,
                       badge: badge(for: tab))
        }
        .buttonStyle(.plain)
        .disabled(!client.isPaired)
    }

    private func badge(for tab: DashboardTab) -> String? {
        guard client.isPaired else { return nil }
        switch tab {
        case .notifications: return client.notifications.isEmpty ? nil : "\(client.notifications.count)"
        case .messages:
            let unread = phone.threads.filter { $0.unread }.count
            return unread > 0 ? "\(unread)" : nil
        case .files:
            let active = client.transfers.filter { $0.status == .inProgress }.count
            return active > 0 ? "\(active)" : nil
        case .calls: return phone.callState == .idle ? nil : "LIVE"
        case .phoneScreen: return phone.isMirroring ? "LIVE" : nil
        case .camera: return client.isCameraStreaming ? "LIVE" : nil
        default: return nil
        }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconTile(symbol: "iphone", size: 32, radius: 9, iconSize: 15,
                         background: client.isPaired ? Theme.successSoft : Theme.surfaceMuted,
                         foreground: client.isPaired ? Theme.success : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(client.isPaired ? (client.connectedDeviceName ?? "Your phone") : "No phone yet")
                        .font(.lmHeadline).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(deviceDetail).font(.lmCallout).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if client.isPaired {
                StatusChip(tone: .success, label: "Connected")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.borderSubtle))
    }

    private var deviceDetail: String {
        guard client.isPaired else {
            return client.connectionState == "Disconnected" ? "Pair one to get started" : client.connectionState
        }
        let link = client.isWirelessConnection ? "Wi‑Fi" : "USB"
        return client.remoteBatteryPercent.map { "\(link) · \($0)% battery" } ?? link
    }
}
