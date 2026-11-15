import SwiftUI
import AppKit
import AVKit
import Combine
@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import UniformTypeIdentifiers

/**
 * -----------------------------------------------------------------------------
 * LinkMyMacApp: Native macOS Client Application Entry Point
 * -----------------------------------------------------------------------------
 * WHAT IT DOES:
 *   Acts as the SwiftUI `@main` lifecycle orchestrator for UniBridge on macOS.
 *   Instantiates the shared P2P communication client (`MacP2PClient`), hosts
 *   the primary dashboard window (`DashboardView`), and manages a persistent
 *   system tray menu (`MenuBarExtra`).
 *
 * HOW IT DOES IT:
 *   - Uses `@StateObject` to own the network client (`MacP2PClient`).
 *   - Configures activation policy in `AppDelegate` so the window gains focus.
 *   - Provides a split-view desktop dashboard and a lightweight menu bar status item.
 *   - Automatically initiates clipboard monitoring and attempts USB tunnel connection.
 *
 * WHY IT DOES IT:
 *   Cross-device bridging needs both an expansive management workspace (for
 *   photo galleries, camera streams, and active notifications) and a persistent
 *   lightweight menu-bar resident.
 * -----------------------------------------------------------------------------
 */
final class AppDelegate: NSObject, NSApplicationDelegate {
    var subsystems: MacSubsystems?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let sub = MacSubsystems(p2pClient: MacP2PClient.shared)
        sub.startClipboardMonitor()
        self.subsystems = sub

        MacP2PClient.shared.reconnect() // last used host; USB tunnel (127.0.0.1) by default
    }

    /// Files dropped on the Dock icon (or `open -a LinkMyMac file`) go to the phone.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty {
            MacP2PClient.shared.sendFiles(files)
        }
    }
}

/// NSOpenPanel → phone. Shared by the File Sharing tab and the menu bar.
@MainActor
func chooseFilesAndSend(to client: MacP2PClient) {
    let panel = NSOpenPanel()
    panel.title = "Send Files to Phone"
    panel.prompt = "Send"
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    NSApp.activate(ignoringOtherApps: true)
    if panel.runModal() == .OK {
        client.sendFiles(panel.urls)
    }
}

@main
struct LinkMyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var p2pClient = MacP2PClient.shared

    var body: some Scene {
        WindowGroup("UniBridge (LinkMyMac)") {
            DashboardView(p2pClient: p2pClient)
                .frame(minWidth: 920, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))

        MenuBarExtra("UniBridge", systemImage: p2pClient.connectedDeviceName != nil ? "iphone.radiowaves.left.and.right" : "iphone.slash") {
            VStack(alignment: .leading, spacing: 8) {
                Text(p2pClient.connectedDeviceName ?? "No Android Connected")
                    .font(.headline)

                Text("Status: \(p2pClient.connectionState)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let battery = p2pClient.remoteBatteryPercent {
                    Text("Phone Battery: \(battery)%")
                        .font(.caption)
                }

                Divider()

                Button("Connect via USB Tunnel (127.0.0.1:8765)") {
                    p2pClient.connectDirect(host: "127.0.0.1", port: 8765)
                }

                Button("Refresh Media Gallery") {
                    p2pClient.requestMediaIndex(offset: 0, limit: 30)
                }

                Button("Send Files to Phone…") {
                    chooseFilesAndSend(to: p2pClient)
                }
                .disabled(!p2pClient.isPaired)

                Button("Turn On Phone Hotspot…") {
                    p2pClient.phone.requestHotspot()
                }
                .disabled(!p2pClient.isPaired)

                Divider()

                Button("Quit UniBridge") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(8)
        }
    }
}

/// One Android storage folder in "Group by Folder" mode.
struct MediaFolder: Identifiable {
    let path: String
    let items: [RemoteMediaItem]
    var id: String { path }
    var name: String { items.first.map { $0.folderName.isEmpty ? "Other" : $0.folderName } ?? "Other" }
}

/**
 * -----------------------------------------------------------------------------
 * Navigation Tab Enum for Sidebar Selection
 * -----------------------------------------------------------------------------
 */
enum DashboardTab: String, CaseIterable, Identifiable {
    case notifications = "Notifications"
    case photos = "Photos"
    case videos = "Videos"
    case files = "File Sharing"
    case messages = "Messages"
    case calls = "Calls"
    case phoneScreen = "Phone Screen"
    case camera = "FaceTime Camera"
    case clipboard = "Universal Clipboard"
    case qrPairing = "QR Code Pairing"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .notifications: return "bell.badge.fill"
        case .photos: return "photo.on.rectangle.angled"
        case .videos: return "film.stack"
        case .files: return "arrow.up.arrow.down.circle.fill"
        case .messages: return "message.fill"
        case .calls: return "phone.fill"
        case .phoneScreen: return "iphone.gen3"
        case .camera: return "video.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .qrPairing: return "qrcode.viewfinder"
        }
    }
}

/**
 * -----------------------------------------------------------------------------
 * DashboardView: Modern macOS Sequoia-Style Continuity Dashboard
 * -----------------------------------------------------------------------------
 * WHAT IT DOES:
 *   Hosts the primary desktop interface:
 *     - Left Sidebar: App branding, paired device card with live battery and
 *       transport badges, primary navigation tabs with unread/status badges,
 *       and manual connection utilities.
 *     - Detail Area: Dynamic content switcher displaying Notifications,
 *       Camera Roll Gallery, FaceTime Continuity Camera, Universal Clipboard,
 *       or QR Pairing Hub.
 *
 * HOW IT DOES IT:
 *   - Uses `NavigationSplitView` with a fixed-range sidebar column width.
 *   - Driven by `@State private var selectedTab: DashboardTab`.
 *   - Implements rich glassmorphic cards (`.ultraThinMaterial`), hover states,
 *     and fluid layout geometry.
 *
 * WHY IT DOES IT:
 *   Matches the native Apple Continuity design language, ensuring seamless
 *   ergonomics identical to iPhone Mirroring, FaceTime, and macOS System Settings.
 * -----------------------------------------------------------------------------
 */
struct DashboardView: View {
    @ObservedObject var p2pClient: MacP2PClient
    @State private var selectedTab: DashboardTab = .notifications

    // Sub-view UI States
    @State private var manualHost: String = UserDefaults.standard.string(forKey: MacP2PClient.lastHostKey) ?? "127.0.0.1"
    @State private var pairingCodeInput: String = ""
    @State private var isDropTargeted: Bool = false
    @State private var manualPort: String = "8765"
    @State private var replyTexts: [String: String] = [:]
    @State private var customClipboardInput: String = ""
    @State private var selectedLens: String = "BACK"
    @State private var snapshotStatusText: String? = nil
    @State private var isShowingQRScanner: Bool = false
    @State private var qrPasteString: String = ""
    @State private var qrStatusMessage: String? = nil
    @State private var isCameraFlipping: Bool = false
    @State private var showDeleteConfirmation: Bool = false
    @State private var itemPendingDeletion: RemoteMediaItem? = nil
    @State private var previewMediaItem: RemoteMediaItem? = nil
    @State private var previewAutoplay: Bool = false
    @AppStorage("LinkMyMac.groupMediaByFolder") private var groupMediaByFolder = false
    @State private var collapsedFolders: Set<String> = []
    @State private var notificationSearchText: String = ""
    @State private var photoSearchText: String = ""
    @State private var showFaceTimeGuide: Bool = false

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 320)
        } detail: {
            detailContent
                .background(Color(NSColor.windowBackgroundColor))
        }
        .onChange(of: selectedTab) { photoSearchText = "" } // each section starts unfiltered
        .sheet(isPresented: $isShowingQRScanner) {
            QRCameraScannerSheet(p2pClient: p2pClient, isPresented: $isShowingQRScanner)
        }
        .sheet(isPresented: $showFaceTimeGuide) {
            FaceTimeIntegrationGuideSheet(isPresented: $showFaceTimeGuide, p2pClient: p2pClient)
        }
        .sheet(item: $previewMediaItem) { item in
            PhotoDetailPreviewSheet(item: item, p2pClient: p2pClient, autoplay: previewAutoplay)
        }
        .confirmationDialog(
            itemPendingDeletion?.isVideo == true ? "Permanently Delete Video?" : "Permanently Delete Photo?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete from Android Phone", role: .destructive) {
                if let item = itemPendingDeletion {
                    p2pClient.deleteMediaItem(mediaId: item.id)
                    itemPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {
                itemPendingDeletion = nil
            }
        } message: {
            Text("It will be permanently removed from your Android device's storage.")
        }
    }

    // =========================================================================
    // Sidebar: Branding, Device Telemetry & Navigation Tabs
    // =========================================================================
    private var sidebarContent: some View {
        VStack(spacing: 0) {
            // Header: UniBridge Branding
            HStack(spacing: 12) {
                if let logoUrl = Bundle.main.url(forResource: "logo", withExtension: "png"),
                   let logoImage = NSImage(contentsOf: logoUrl) {
                    Image(nsImage: logoImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 48, height: 48)
                        .cornerRadius(10)
                        .shadow(color: Color.blue.opacity(0.35), radius: 6, y: 2)
                } else {
                    Image(systemName: "infinity.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("UniBridge")
                        .font(.title3.bold())
                    Text("Apple Continuity for Android")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            // Paired Device Card
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(p2pClient.isPaired ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                        .shadow(color: p2pClient.isPaired ? Color.green.opacity(0.6) : Color.clear, radius: 4)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(p2pClient.connectedDeviceName ?? "Searching for Android...")
                            .font(.subheadline.bold())
                            .lineLimit(1)
                        Text(p2pClient.connectionState)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if let battery = p2pClient.remoteBatteryPercent {
                        HStack(spacing: 4) {
                            Image(systemName: batteryIcon(for: battery))
                                .font(.caption)
                                .foregroundColor(batteryColor(for: battery))
                            Text("\(battery)%")
                                .font(.caption2.bold())
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(6)
                    }
                }

                // Transport Pill & Reconnect
                HStack {
                    Label(
                        p2pClient.connectedDeviceName != nil
                            ? (p2pClient.isWirelessConnection ? "Wi-Fi LAN Active" : "USB Tunnel Active")
                            : (p2pClient.discoveredPeers.first != nil ? "Wi-Fi Device Found" : p2pClient.directEndpointLabel),
                        systemImage: p2pClient.isWirelessConnection ? "wifi" : "cable.connector"
                    )
                    .font(.caption2.bold())
                    .foregroundColor(p2pClient.isWirelessConnection ? .cyan : .secondary)

                    Spacer()

                    if let peer = p2pClient.discoveredPeers.first, p2pClient.connectedDeviceName == nil {
                        Button("Connect Wi-Fi") {
                            p2pClient.connect(to: peer)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.mini)
                    } else {
                        Button {
                            p2pClient.reconnect()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .help("Reconnect (Wi-Fi if the phone is visible, otherwise \(p2pClient.directEndpointLabel))")
                    }
                }

                if p2pClient.needsPairingCode {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Enter the code shown in LinkMyMac on your phone")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        HStack(spacing: 6) {
                            TextField("ABC 123", text: $pairingCodeInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .onSubmit(submitPairingCode)
                            Button("Pair", action: submitPairingCode)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(normalizedPairingCode.count < 6)
                        }
                    }
                }
                if let error = p2pClient.pairingError {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                }
                if p2pClient.isPaired {
                    PhoneStatusRow(phone: p2pClient.phone)
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(12)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // Primary Navigation Items
            List(DashboardTab.allCases, selection: $selectedTab) { tab in
                NavigationLink(value: tab) {
                    HStack(spacing: 12) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 15))
                            .foregroundColor(tabColor(for: tab))
                            .frame(width: 22)

                        Text(tab.rawValue)
                            .font(.subheadline)

                        Spacer()

                        // Contextual Badges
                        switch tab {
                        case .notifications:
                            if !p2pClient.notifications.isEmpty {
                                Text("\(p2pClient.notifications.count)")
                                    .font(.caption2.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.red))
                            }
                        case .photos, .videos:
                            if let total = p2pClient.mediaTotals[tab == .videos ? .videos : .photos] {
                                Text("\(total)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        case .files:
                            let active = p2pClient.transfers.filter { $0.status == .inProgress }.count
                            if active > 0 {
                                Text("\(active)")
                                    .font(.caption2.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.teal))
                            }
                        case .camera:
                            if p2pClient.isCameraStreaming {
                                HStack(spacing: 4) {
                                    Circle().fill(Color.red).frame(width: 6, height: 6)
                                    Text("LIVE")
                                        .font(.system(size: 9, weight: .heavy))
                                        .foregroundColor(.white)
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.red.opacity(0.85)))
                            }
                        case .clipboard:
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                        case .messages, .calls, .phoneScreen:
                            PhoneTabBadge(phone: p2pClient.phone, tab: tab)
                        case .qrPairing:
                            EmptyView()
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.sidebar)

            Spacer()

            // Discovered Bonjour Peers Section
            if !p2pClient.discoveredPeers.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LAN Discovered Devices")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)

                    ForEach(p2pClient.discoveredPeers) { peer in
                        Button {
                            p2pClient.connect(to: peer)
                        } label: {
                            HStack {
                                Image(systemName: "iphone.gen3")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                                Text(peer.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                Spacer()
                                Text("Connect")
                                    .font(.caption2)
                                    .foregroundColor(.accentColor)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.06))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    // =========================================================================
    // Detail Switcher: Selects Sub-View by Sidebar Selection
    // =========================================================================
    @ViewBuilder
    private var detailContent: some View {
        switch selectedTab {
        case .notifications:
            notificationsDetailView
        case .photos:
            mediaGalleryView(.photos)
        case .videos:
            mediaGalleryView(.videos)
        case .files:
            filesDetailView
        case .camera:
            cameraDetailView
        case .clipboard:
            clipboardDetailView
        case .messages:
            MessagesView(phone: p2pClient.phone)
        case .calls:
            CallsView(phone: p2pClient.phone)
        case .phoneScreen:
            PhoneScreenView(phone: p2pClient.phone)
        case .qrPairing:
            qrPairingDetailView
        }
    }

    // =========================================================================
    // Scope 1: Notifications Detail View
    // =========================================================================
    private var notificationsDetailView: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mirrored Notifications")
                        .font(.title2.bold())
                    Text("\(filteredNotifications.count) active alerts from Android")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Search Bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("Filter notifications...", text: $notificationSearchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .frame(width: 140)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)

                if !p2pClient.notifications.isEmpty {
                    Button(role: .destructive) {
                        p2pClient.clearAllNotificationsOnAndroid()
                    } label: {
                        Label("Clear All on Android", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .help("Dismiss all clearable notifications from the Android status bar")
                }

                Button {
                    p2pClient.requestNotificationSync()
                } label: {
                    Label("Sync", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))

            Divider()

            if filteredNotifications.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("No Notifications")
                        .font(.title3.bold())
                    Text("Active notifications from WhatsApp, Messages, Slack, and other apps will appear here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)

                    Button("Sync From Phone") {
                        p2pClient.requestNotificationSync()
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredNotifications) { notif in
                            notificationCard(notif)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var filteredNotifications: [MirroredNotification] {
        if notificationSearchText.isEmpty {
            return p2pClient.notifications
        } else {
            let q = notificationSearchText.lowercased()
            return p2pClient.notifications.filter {
                $0.appName.lowercased().contains(q) ||
                $0.title.lowercased().contains(q) ||
                $0.body.lowercased().contains(q)
            }
        }
    }

    private func notificationCard(_ notif: MirroredNotification) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                // Real Brand App Icon
                if let iconData = notif.appIconData,
                   let nsImage = NSImage(data: iconData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                        .cornerRadius(8)
                        .shadow(color: Color.black.opacity(0.15), radius: 2, y: 1)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "app.badge.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.blue)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(notif.appName)
                            .font(.subheadline.bold())
                            .foregroundColor(.primary)

                        if notif.postTimeMs > 0 {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(formatNotificationTime(notif.postTimeMs))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    if !notif.title.isEmpty {
                        Text(notif.title)
                            .font(.headline)
                            .foregroundColor(.primary)
                    }

                    if !notif.body.isEmpty {
                        Text(notif.body)
                            .font(.body)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Button {
                    p2pClient.dismissNotificationOnAndroid(key: notif.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Dismiss Notification on Mac & Android")
            }

            // Inline Reply Composer
            if let replyAction = notif.actions.first(where: { $0.supportsInlineReply }) {
                HStack(spacing: 8) {
                    TextField(
                        replyAction.replyPlaceholder,
                        text: Binding(
                            get: { replyTexts[notif.id] ?? "" },
                            set: { replyTexts[notif.id] = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        submitReply(for: notif, action: replyAction)
                    }

                    Button("Reply") {
                        submitReply(for: notif, action: replyAction)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled((replyTexts[notif.id] ?? "").isEmpty)
                }
                .padding(.leading, 48)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: Color.black.opacity(0.04), radius: 3, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func submitReply(for notif: MirroredNotification, action: NotificationActionOption) {
        let text = replyTexts[notif.id] ?? ""
        guard !text.isEmpty else { return }
        p2pClient.sendNotificationReply(
            notificationKey: notif.id,
            actionId: action.id,
            replyText: text
        )
        replyTexts[notif.id] = ""
    }

    // =========================================================================
    // Scope 2: Photos and Videos (one sidebar section each, paged separately)
    // =========================================================================
    private func mediaGalleryView(_ kind: MediaKind) -> some View {
        let isVideos = kind == .videos
        let items = filteredMediaItems(kind)
        let loaded = p2pClient.mediaItems(kind).count
        let total = p2pClient.mediaTotals[kind]
        let syncTitle = isVideos ? "Sync All Videos" : "Sync All Photos"
        return VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isVideos ? "Videos" : "Photos")
                        .font(.title2.bold())
                    Text("\(loaded) loaded\(total.map { " of \($0) on the phone" } ?? "")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Search Bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField(isVideos ? "Search videos..." : "Search photos...", text: $photoSearchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .frame(width: 140)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)

                Button {
                    groupMediaByFolder.toggle()
                } label: {
                    Label(groupMediaByFolder ? "Ungroup" : "Group by Folder",
                          systemImage: groupMediaByFolder ? "square.grid.2x2" : "folder")
                }
                .buttonStyle(.bordered)
                .help("Group by the folder each item is stored in on the phone (Camera, Screenshots, WhatsApp…)")

                if p2pClient.syncingKind == kind {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Syncing (\(loaded)\(total.map { "/\($0)" } ?? ""))...")
                            .font(.caption2.bold())
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(8)
                } else {
                    Button {
                        p2pClient.syncAllGallery(kind)
                    } label: {
                        Label(syncTitle, systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(p2pClient.syncingKind != nil) // one sync at a time
                }

                Button {
                    p2pClient.requestMediaIndex(kind, offset: 0, limit: 50)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))

            Divider()

            if items.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    Image(systemName: isVideos ? "film.stack" : "photo.on.rectangle.angled")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text(isVideos ? "No Videos Found" : "No Photos Found")
                        .font(.title3.bold())
                    Text("Click '\(syncTitle)' above to index them from your Android device.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)

                    Button("Sync Now") {
                        p2pClient.syncAllGallery(kind)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(p2pClient.syncingKind != nil)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 14)], spacing: 14,
                              pinnedViews: [.sectionHeaders]) {
                        if groupMediaByFolder {
                            ForEach(mediaFolders(items)) { folder in
                                Section {
                                    if !collapsedFolders.contains(folderKey(kind, folder)) {
                                        ForEach(folder.items) { item in
                                            mediaCard(item)
                                        }
                                    }
                                } header: {
                                    folderHeader(folder, kind: kind)
                                }
                            }
                        } else {
                            ForEach(items) { item in
                                mediaCard(item)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    /// Folders ordered by their newest item (items arrive newest-first), like Android's album list.
    private func mediaFolders(_ items: [RemoteMediaItem]) -> [MediaFolder] {
        var order: [String] = []
        var groups: [String: [RemoteMediaItem]] = [:]
        for item in items {
            if groups[item.folderPath] == nil { order.append(item.folderPath) }
            groups[item.folderPath, default: []].append(item)
        }
        return order.map { MediaFolder(path: $0, items: groups[$0, default: []]) }
    }

    /// Photos and Videos can both have e.g. DCIM/Camera/, so collapse state is per section.
    private func folderKey(_ kind: MediaKind, _ folder: MediaFolder) -> String {
        "\(kind.rawValue):\(folder.path)"
    }

    /// Whole header toggles; the chevron points right when collapsed, down when open.
    private func folderHeader(_ folder: MediaFolder, kind: MediaKind) -> some View {
        let key = folderKey(kind, folder)
        let collapsed = collapsedFolders.contains(key)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if collapsed {
                    collapsedFolders.remove(key)
                } else {
                    collapsedFolders.insert(key)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Image(systemName: "folder.fill")
                    .foregroundColor(.accentColor)
                Text(folder.name)
                    .font(.headline)
                Text(folder.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text("\(folder.items.count)")
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color(NSColor.windowBackgroundColor)) // pinned header: hide cards scrolling under it
        .help(collapsed ? "Expand folder" : "Collapse folder")
    }

    private func filteredMediaItems(_ kind: MediaKind) -> [RemoteMediaItem] {
        let items = p2pClient.mediaItems(kind)
        guard !photoSearchText.isEmpty else { return items }
        let query = photoSearchText.lowercased()
        return items.filter { $0.displayName.lowercased().contains(query) }
    }

    private func mediaCard(_ item: RemoteMediaItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // Thumbnail: the grid column sets the size and the image fills it, cropped.
                // scaledToFill + frame(height:) alone let a landscape thumbnail (most videos)
                // claim 140 × 16/9 ≈ 249 pt and push the card past its column.
                Color.gray.opacity(0.18)
                    .frame(maxWidth: .infinity)
                    .frame(height: 140)
                    .overlay {
                        if let data = item.thumbnailData,
                           let nsImage = NSImage(data: data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Image(systemName: item.isVideo ? "film" : "photo")
                                .font(.largeTitle)
                                .foregroundColor(.gray)
                        }
                    }
                    .clipped()
                .overlay(alignment: .bottomLeading) {
                    if item.isVideo {
                        Label(formatDuration(item.durationMs), systemImage: "play.fill")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                            .padding(6)
                    }
                }
                .overlay {
                    if item.isVideo {
                        Button {
                            previewAutoplay = true
                            previewMediaItem = item
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 40))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                        .help("Play")
                    }
                }
                .cornerRadius(10)
                .contentShape(Rectangle())
                .onTapGesture {
                    previewAutoplay = false
                    previewMediaItem = item
                }

                // Downloaded badge
                if p2pClient.localFileURL(for: item.id) != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .background(Circle().fill(Color.white))
                        .padding(8)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.caption.bold())
                    .lineLimit(1)
                Text("\(formatBytes(item.sizeBytes)) • \(item.width)×\(item.height)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let download = mediaDownload(for: item) {
                    ProgressView(value: Double(download.bytesTransferred), total: Double(max(download.totalBytes, 1)))
                        .controlSize(.small)
                }
            }

            // Action Toolbar
            HStack(spacing: 8) {
                Button {
                    p2pClient.downloadFullResolutionMedia(mediaId: item.id)
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                }
                .buttonStyle(.plain)
                .font(.system(size: 18))
                .foregroundColor(.blue)
                .help(item.isVideo ? "Download Video to ~/Downloads" : "Download Full Resolution Photo to ~/Downloads")

                Button {
                    shareMediaItem(item)
                } label: {
                    Image(systemName: "square.and.arrow.up.circle.fill")
                }
                .buttonStyle(.plain)
                .font(.system(size: 18))
                .foregroundColor(.accentColor)
                .help("Share with AirDrop, Messages, Mail")

                Spacer()

                Button {
                    itemPendingDeletion = item
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash.circle.fill")
                }
                .buttonStyle(.plain)
                .font(.system(size: 18))
                .foregroundColor(.red.opacity(0.85))
                .help("Delete permanently from Android device")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: Color.black.opacity(0.04), radius: 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // =========================================================================
    // Scope 3: FaceTime Continuity Camera Detail View
    // =========================================================================
    private var cameraDetailView: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("FaceTime Continuity Camera")
                            .font(.title2.bold())
                        if p2pClient.isCameraSwitching {
                            ProgressView().controlSize(.small)
                            Text("Switching...")
                                .font(.caption2.bold())
                                .foregroundColor(.cyan)
                        }
                    }
                    Text("1-Click Front ⇄ Back switch with device orientation tracking matching iPhone")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Explicit Lens Segmented Picker
                Picker("Active Lens", selection: Binding(
                    get: { p2pClient.currentCameraLens },
                    set: { newLens in
                        selectedLens = newLens
                        if p2pClient.isCameraStreaming {
                            p2pClient.switchCameraLens(newLens)
                        }
                    }
                )) {
                    Text("🤳 Front (FaceTime)").tag("FRONT")
                    Text("📷 Back (Main 4K)").tag("BACK")
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                .disabled(p2pClient.isCameraSwitching)

                Button {
                    showFaceTimeGuide = true
                } label: {
                    Label("FaceTime Help", systemImage: "questionmark.circle")
                }
                .buttonStyle(.bordered)
                .help("Learn how to use Android camera in Apple FaceTime & Zoom calls")

                if p2pClient.isCameraStreaming {
                    Button(role: .destructive) {
                        p2pClient.stopCameraStream()
                    } label: {
                        Label("Stop Camera", systemImage: "video.slash.fill")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        p2pClient.startCameraStream(lens: selectedLens)
                    } label: {
                        Label("Start Camera", systemImage: "video.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))

            Divider()

            // Viewport Canvas
            ZStack {
                Color.black.opacity(0.96)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let frame = p2pClient.latestCameraFrame {
                    Image(nsImage: frame)
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(14)
                        .padding(12)
                        .rotation3DEffect(.degrees(isCameraFlipping ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: isCameraFlipping)

                    // Top Info Overlay
                    VStack {
                        HStack {
                            HStack(spacing: 6) {
                                Circle().fill(Color.red).frame(width: 8, height: 8)
                                Text("LIVE • \(p2pClient.currentCameraLens == "FRONT" ? "🤳 FRONT (FACETIME HD)" : "📷 BACK (MAIN 4K)")")
                                    .font(.caption2.bold())
                                    .foregroundColor(.white)
                                Text("• \(p2pClient.cameraRotationDegrees)°")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.black.opacity(0.65))
                            .cornerRadius(8)

                            Spacer()

                            if let status = snapshotStatusText {
                                Text(status)
                                    .font(.caption.bold())
                                    .foregroundColor(.green)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.black.opacity(0.75))
                                    .cornerRadius(8)
                            }
                        }
                        .padding(16)

                        Spacer()

                        // Floating FaceTime Frosted Glass Control Dock
                        HStack(spacing: 20) {
                            // Camera Flip Button
                            Button {
                                isCameraFlipping.toggle()
                                p2pClient.toggleCameraLens()
                                selectedLens = p2pClient.currentCameraLens
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color.white.opacity(0.2))
                                        .frame(width: 48, height: 48)
                                    if p2pClient.isCameraSwitching {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                                            .font(.system(size: 20))
                                            .foregroundColor(.white)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(p2pClient.isCameraSwitching)
                            .help("Flip Camera Lens (Front ⇄ Back)")

                            // Always-on-Top Floating PiP Window Button
                            Button {
                                FloatingCameraManager.shared.toggle(client: p2pClient)
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color.white.opacity(0.2))
                                        .frame(width: 48, height: 48)
                                    Image(systemName: "pip.enter")
                                        .font(.system(size: 19))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Pop Out Floating Video Window (Over FaceTime / Zoom)")

                            // Shutter Snapshot Button
                            Button {
                                takeSnapshot(from: frame)
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 56, height: 56)
                                    Circle()
                                        .stroke(Color.black.opacity(0.25), lineWidth: 2)
                                        .frame(width: 48, height: 48)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Take Snapshot Photo")

                            // Pause / Resume Video
                            Button {
                                if p2pClient.isCameraStreaming {
                                    p2pClient.stopCameraStream()
                                } else {
                                    p2pClient.startCameraStream(lens: selectedLens)
                                }
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(p2pClient.isCameraStreaming ? Color.red : Color.green)
                                        .frame(width: 48, height: 48)
                                    Image(systemName: p2pClient.isCameraStreaming ? "video.slash.fill" : "video.fill")
                                        .font(.system(size: 19))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(p2pClient.isCameraStreaming ? "Pause Camera Stream" : "Resume Camera Stream")
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.68))
                                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 1))
                        )
                        .padding(.bottom, 24)
                    }

                    // Switching Lens Overlay
                    if p2pClient.isCameraSwitching {
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.regular)
                            Text("Switching to \(p2pClient.currentCameraLens == "FRONT" ? "Front (FaceTime)" : "Back (Main)") Lens...")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        .padding(24)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(16)
                    }

                    // Error Message Banner if any
                    if let err = p2pClient.cameraErrorMessage {
                        VStack(spacing: 8) {
                            Label(err, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.bold())
                                .foregroundColor(.yellow)
                            Button("Retry Connection") {
                                p2pClient.switchCameraLens(p2pClient.currentCameraLens)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(16)
                        .background(Color.black.opacity(0.88))
                        .cornerRadius(12)
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "video.slash.fill")
                            .font(.system(size: 52))
                            .foregroundColor(.gray)
                        Text(p2pClient.isCameraStreaming ? "Opening Android Camera..." : "FaceTime Camera Inactive")
                            .font(.title3.bold())
                            .foregroundColor(.white)
                        Text("Use your phone as a high-resolution wireless Mac webcam with Front ⇄ Back switching")
                            .font(.caption)
                            .foregroundColor(.gray)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 340)

                        HStack(spacing: 12) {
                            Button {
                                p2pClient.startCameraStream(lens: selectedLens)
                            } label: {
                                Label("Start Live Stream", systemImage: "video.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)

                            Button {
                                showFaceTimeGuide = true
                            } label: {
                                Label("FaceTime Setup Guide", systemImage: "questionmark.circle")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                    }
                }
            }
        }
    }

    private func takeSnapshot(from frame: NSImage) {
        if let tiff = frame.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let jpeg = bitmap.representation(using: .jpeg, properties: [:]) {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let url = downloads.appendingPathComponent("UniBridge_Snapshot_\(Int(Date().timeIntervalSince1970)).jpg")
            try? jpeg.write(to: url)
            snapshotStatusText = "Snapshot Saved to ~/Downloads!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                snapshotStatusText = nil
            }
        }
    }

    // =========================================================================
    // Scope 4: Universal Clipboard Detail View
    // =========================================================================
    private var clipboardDetailView: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Universal Clipboard")
                        .font(.title2.bold())
                    Text("Instant bi-directional copy & paste between macOS and Android")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text("SYNC ACTIVE")
                        .font(.caption2.bold())
                        .foregroundColor(.green)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.12))
                .cornerRadius(6)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    // Info Banner
                    HStack(spacing: 12) {
                        Image(systemName: "info.circle.fill")
                            .font(.title3)
                            .foregroundColor(.blue)
                        Text("Any text copied with ⌘C on Mac is automatically sent to your phone. Any text copied on your Android phone is automatically available to paste with ⌘V on Mac.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.08))
                    .cornerRadius(10)

                    // Dual Live Cards: Mac Clipboard & Android Clipboard
                    HStack(alignment: .top, spacing: 14) {
                        // Mac Clipboard Card
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("Current Mac Clipboard (⌘C)", systemImage: "laptopcomputer")
                                    .font(.subheadline.bold())
                                Spacer()
                            }

                            Text(NSPasteboard.general.string(forType: .string) ?? "(Clipboard is empty)")
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(5)
                                .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                                .padding(10)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(8)

                            Button("Push to Phone Now") {
                                if let str = NSPasteboard.general.string(forType: .string) {
                                    p2pClient.sendClipboardText(str)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(14)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(12)

                        // Phone Clipboard Card
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label("Last from Android Phone", systemImage: "iphone")
                                    .font(.subheadline.bold())
                                Spacer()
                            }

                            Text(p2pClient.lastSyncedClipboardText.isEmpty ? "(No text received from phone yet)" : p2pClient.lastSyncedClipboardText)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(5)
                                .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                                .padding(10)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(8)

                            Button("Copy to Mac Clipboard (⌘V)") {
                                guard !p2pClient.lastSyncedClipboardText.isEmpty else { return }
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(p2pClient.lastSyncedClipboardText, forType: .string)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(p2pClient.lastSyncedClipboardText.isEmpty)
                        }
                        .padding(14)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(12)
                    }

                    // Custom Push Composer
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Send Custom Text to Phone Clipboard")
                            .font(.subheadline.bold())

                        HStack {
                            TextField("Type or paste custom text or link to send...", text: $customClipboardInput)
                                .textFieldStyle(.roundedBorder)

                            Button("Send to Phone") {
                                guard !customClipboardInput.isEmpty else { return }
                                p2pClient.sendClipboardText(customClipboardInput)
                                customClipboardInput = ""
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(12)

                    // Recent History
                    if !p2pClient.clipboardSyncHistory.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recent Clipboard History (\(p2pClient.clipboardSyncHistory.count))")
                                .font(.subheadline.bold())

                            VStack(spacing: 6) {
                                ForEach(p2pClient.clipboardSyncHistory, id: \.self) { item in
                                    HStack {
                                        Text(item)
                                            .font(.caption)
                                            .lineLimit(1)
                                        Spacer()
                                        Button("Copy") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(item, forType: .string)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                    }
                                    .padding(8)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(6)
                                }
                            }
                        }
                        .padding(14)
                        .background(Color.secondary.opacity(0.06))
                        .cornerRadius(12)
                    }
                }
                .padding(20)
            }
        }
    }

    // =========================================================================
    // Scope 5: QR Code Pairing Detail View
    // =========================================================================
    private var qrPairingDetailView: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pair Android via QR Code")
                        .font(.title2.bold())
                    Text("Connect instantly with Mac webcam scanner, image import, or JSON token")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))

            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // Quick Wireless Connect Card (mDNS Auto-Discovery & Direct Wi-Fi)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "wifi")
                                .font(.title2)
                                .foregroundColor(.cyan)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connect Over Local Wi-Fi (No Cable)")
                                    .font(.headline)
                                Text("Seamless peer-to-peer connection over your local Wi-Fi network.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Circle()
                                .fill(p2pClient.connectedDeviceName != nil ? Color.green : Color.cyan)
                                .frame(width: 10, height: 10)
                        }

                        if let peer = p2pClient.discoveredPeers.first {
                            HStack {
                                Text("Discovered Phone:")
                                    .font(.subheadline.bold())
                                Text(peer.name)
                                    .font(.system(.subheadline, design: .monospaced))
                                    .foregroundColor(.cyan)
                            }

                            Button {
                                p2pClient.connect(to: peer)
                            } label: {
                                Label("Connect Wirelessly to \(peer.name)", systemImage: "wifi")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        } else {
                            Text("No phone found via Bonjour yet. Check both devices are on the same Wi-Fi, or enter the phone's IP under Manual IP below.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Color.cyan.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cyan.opacity(0.3), lineWidth: 1))
                    .cornerRadius(12)

                    // Option 1: Live Webcam Scan
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Method 1: Scan Phone Screen with Mac Camera", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                        Text("Hold your Android phone's UniBridge QR code in front of your Mac's FaceTime HD camera.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button {
                            isShowingQRScanner = true
                        } label: {
                            Label("Open Mac Webcam Scanner...", systemImage: "camera.viewfinder")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(12)

                    // Option 2: Image Import
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Method 2: Import QR Code Screenshot", systemImage: "photo.badge.plus")
                            .font(.headline)
                        Text("Select a screenshot or image of the QR code from your Mac disk.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button {
                            selectAndScanQRImage()
                        } label: {
                            Label("Choose Image File...", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(12)

                    // Option 3: Manual JSON Paste
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Method 3: Paste QR JSON Token", systemImage: "doc.text")
                            .font(.headline)
                        Text("Paste the pairing JSON payload directly from your phone.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField("Paste QR Code JSON payload...", text: $qrPasteString)
                                .textFieldStyle(.roundedBorder)

                            Button("Connect") {
                                let success = p2pClient.connectViaQRPayload(qrPasteString)
                                qrStatusMessage = success ? "Connecting via QR payload..." : "Invalid QR Code JSON payload."
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(qrPasteString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }

                        if let status = qrStatusMessage {
                            Text(status)
                                .font(.caption.bold())
                                .foregroundColor(.blue)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(12)

                    // Manual IP Fallback
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Manual IP & USB Fallback", systemImage: "network")
                            .font(.headline)

                        HStack(spacing: 12) {
                            TextField("Host IP", text: $manualHost)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 140)
                            TextField("Port", text: $manualPort)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 70)

                            Button("Connect Direct") {
                                let port = UInt16(manualPort) ?? 8765
                                p2pClient.connectDirect(host: manualHost, port: port)
                            }
                            .buttonStyle(.bordered)

                            Button("Connect via USB (127.0.0.1)") {
                                p2pClient.connectDirect(host: "127.0.0.1", port: 8765)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(12)
                }
                .padding(20)
            }
        }
    }

    // =========================================================================
    // File Sharing: drop zone + transfer list (both directions)
    // =========================================================================
    private var filesDetailView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("File Sharing")
                        .font(.title2.bold())
                    Text("Files you send land in the phone's Download/LinkMyMac folder. Files shared from the phone land in ~/Downloads.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if p2pClient.transfers.contains(where: { $0.status != .inProgress }) {
                    Button("Clear Finished") { p2pClient.clearFinishedTransfers() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.6))

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.up.on.square")
                            .font(.system(size: 34))
                            .foregroundColor(isDropTargeted ? .accentColor : .secondary)
                        Text(p2pClient.isPaired
                             ? "Drop files here to send them to \(p2pClient.connectedDeviceName ?? "your phone")"
                             : "Connect and pair your phone to send files")
                            .font(.headline)
                        Text("On the phone: Share → LinkMyMac Companion, or “Send Files to Mac” in the app.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button {
                            chooseFilesAndSend(to: p2pClient)
                        } label: {
                            Label("Choose Files…", systemImage: "folder")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!p2pClient.isPaired)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(28)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7]))
                            .foregroundColor(isDropTargeted ? .accentColor : Color.secondary.opacity(0.4))
                    )
                    .dropDestination(for: URL.self) { urls, _ in
                        guard p2pClient.isPaired else { return false }
                        p2pClient.sendFiles(urls)
                        return true
                    } isTargeted: { isDropTargeted = $0 }

                    if p2pClient.transfers.isEmpty {
                        Text("No transfers yet")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(p2pClient.transfers) { transfer in
                                transferRow(transfer)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    private func transferRow(_ transfer: FileTransfer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.direction == .toPhone ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .font(.title2)
                .foregroundColor(transfer.direction == .toPhone ? .blue : .green)

            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.name)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                switch transfer.status {
                case .inProgress:
                    if transfer.totalBytes > 0 {
                        ProgressView(value: Double(min(transfer.bytesTransferred, transfer.totalBytes)),
                                     total: Double(transfer.totalBytes))
                        Text("\(formatBytes(transfer.bytesTransferred)) of \(formatBytes(transfer.totalBytes))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                case .done:
                    Text(transfer.direction == .toPhone
                         ? "Saved on phone • \(formatBytes(transfer.totalBytes))"
                         : "Saved to Downloads • \(formatBytes(transfer.bytesTransferred))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .failed(let reason):
                    Text("Failed: \(reason)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Spacer()

            if let url = transfer.localURL {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "eye") }
                    .buttonStyle(.borderless)
                    .help("Open")
                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(10)
    }

    /// Letters and digits only, so "abc 123" and "ABC-123" both work.
    private var normalizedPairingCode: String {
        pairingCodeInput.filter { $0.isLetter || $0.isNumber }.uppercased()
    }

    private func submitPairingCode() {
        guard normalizedPairingCode.count >= 6 else { return }
        p2pClient.submitPairingCode(normalizedPairingCode)
        pairingCodeInput = ""
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    private func tabColor(for tab: DashboardTab) -> Color {
        switch tab {
        case .notifications: return .red
        case .photos: return .blue
        case .videos: return .indigo
        case .files: return .teal
        case .messages: return .mint
        case .calls: return .cyan
        case .phoneScreen: return .pink
        case .camera: return .green
        case .clipboard: return .purple
        case .qrPairing: return .orange
        }
    }

    private func batteryIcon(for level: Int) -> String {
        switch level {
        case 0..<20: return "battery.0"
        case 20..<50: return "battery.25"
        case 50..<80: return "battery.50"
        default: return "battery.100"
        }
    }

    private func batteryColor(for level: Int) -> Color {
        if level <= 20 { return .red }
        if level <= 40 { return .orange }
        return .green
    }

    private func formatNotificationTime(_ postTimeMs: Int64) -> String {
        guard postTimeMs > 0 else { return "Just now" }
        let date = Date(timeIntervalSince1970: TimeInterval(postTimeMs) / 1000.0)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// "1:05" or "1:02:03"
    private func formatDuration(_ ms: Int64) -> String {
        Duration.milliseconds(ms).formatted(.time(pattern: ms >= 3_600_000 ? .hourMinuteSecond : .minuteSecond))
    }

    /// The in-flight download of a gallery item, if any (media downloads reuse the file transfer list).
    private func mediaDownload(for item: RemoteMediaItem) -> FileTransfer? {
        p2pClient.transfers.first { $0.id == "media_\(item.id)" && $0.status == .inProgress }
    }

    private func shareMediaItem(_ item: RemoteMediaItem) {
        var itemsToShare: [Any] = []
        if let localUrl = p2pClient.localFileURL(for: item.id) {
            itemsToShare.append(localUrl)
        } else if !item.isVideo, let data = item.thumbnailData, let img = NSImage(data: data) {
            itemsToShare.append(img) // a video's thumbnail isn't the video: download it first instead
        } else {
            p2pClient.downloadFullResolutionMedia(mediaId: item.id)
            return
        }

        guard let currentView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: itemsToShare)
        picker.show(
            relativeTo: NSRect(x: currentView.bounds.midX, y: currentView.bounds.midY, width: 1, height: 1),
            of: currentView,
            preferredEdge: .minY
        )
    }

    private func selectAndScanQRImage() {
        let panel = NSOpenPanel()
        panel.title = "Select QR Code Image"
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) {
            if let decoded = MacP2PClient.decodeQRCode(from: image) {
                qrPasteString = decoded
                let success = p2pClient.connectViaQRPayload(decoded)
                qrStatusMessage = success ? "Connecting via QR payload..." : "Invalid QR Code JSON payload."
            } else {
                qrStatusMessage = "No valid QR code found in selected image."
            }
        }
    }
}

/**
 * -----------------------------------------------------------------------------
 * PhotoDetailPreviewSheet: Interactive Full-Resolution Image Preview Sheet
 * -----------------------------------------------------------------------------
 */
struct PhotoDetailPreviewSheet: View {
    let item: RemoteMediaItem
    @ObservedObject var p2pClient: MacP2PClient
    var autoplay = false
    @Environment(\.dismiss) private var dismiss
    /// Built once, on first Play; making it inside `body` would restart playback on every re-render.
    @State private var player: AVPlayer?
    /// Streams the video from the phone when it isn't downloaded (lives as long as the player).
    @State private var streamLoader: MediaStreamLoader?
    @State private var playback: AVPlayer.TimeControlStatus = .paused

    private var download: FileTransfer? {
        p2pClient.transfers.first { $0.id == "media_\(item.id)" && $0.status == .inProgress }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.headline)
                    Text("\(item.width)×\(item.height) • \(formatBytes(item.sizeBytes))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding([.top, .horizontal])

            Divider()

            ZStack {
                Color.black.opacity(0.9)
                    .cornerRadius(12)

                if let player {
                    VideoPlayer(player: player)
                        .padding(8)
                        .onReceive(player.publisher(for: \.timeControlStatus).receive(on: RunLoop.main)) {
                            playback = $0 // also follows AVKit's own controls
                        }
                } else if !item.isVideo,
                          let localUrl = p2pClient.localFileURL(for: item.id),
                          let img = NSImage(contentsOf: localUrl) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else if let data = item.thumbnailData,
                          let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                        .overlay {
                            if item.isVideo {
                                playOverlay
                            }
                        }
                }
            }
            .frame(minWidth: 480, minHeight: 360)
            .padding(.horizontal)

            HStack {
                if item.isVideo {
                    Button(action: togglePlayback) {
                        Label(playback == .playing ? "Pause" : playback == .waitingToPlayAtSpecifiedRate ? "Buffering…" : "Play",
                              systemImage: playback == .paused ? "play.fill" : "pause.fill")
                            .frame(minWidth: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPlay)
                }

                Button {
                    p2pClient.downloadFullResolutionMedia(mediaId: item.id)
                } label: {
                    Label(item.isVideo ? "Download Video" : "Download Full Resolution", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .disabled(download != nil)

                if let download {
                    ProgressView(value: Double(download.bytesTransferred), total: Double(max(download.totalBytes, 1)))
                        .frame(width: 160)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
            }
            .padding([.bottom, .horizontal])
        }
        .frame(minWidth: 520, minHeight: 460)
        .onAppear { if autoplay { togglePlayback() } }
        .onDisappear {
            player?.pause()
            streamLoader?.stopAll() // tell the phone to stop sending
        }
    }

    /// Big play button over the thumbnail.
    private var playOverlay: some View {
        Button(action: togglePlayback) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 54))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.45))
        }
        .buttonStyle(.plain)
        .disabled(!canPlay)
        .help("Play")
    }

    private var canPlay: Bool {
        p2pClient.isPaired || p2pClient.localFileURL(for: item.id) != nil
    }

    /// Play/pause. Plays the downloaded copy if there is one, otherwise streams it from the phone.
    private func togglePlayback() {
        if player?.currentItem?.status == .failed { // e.g. the connection dropped mid-stream: start over
            streamLoader?.stopAll()
            streamLoader = nil
            player = nil
        }
        if player == nil {
            player = makePlayer()
        }
        guard let player else { return }
        if player.timeControlStatus != .paused {
            player.pause()
            return
        }
        if let current = player.currentItem, current.duration.isNumeric, current.currentTime() >= current.duration {
            player.seek(to: .zero) // finished: play again from the start
        }
        player.play()
    }

    private func makePlayer() -> AVPlayer? {
        if let url = p2pClient.localFileURL(for: item.id) {
            return AVPlayer(url: url)
        }
        guard let loader = p2pClient.makeStreamLoader(for: item) else { return nil }
        streamLoader = loader
        return loader.makePlayer()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/**
 * -----------------------------------------------------------------------------
 * QRCameraScannerSheet: Webcam QR Code Scanner Modal
 * -----------------------------------------------------------------------------
 */
struct QRCameraScannerSheet: View {
    @ObservedObject var p2pClient: MacP2PClient
    @Binding var isPresented: Bool
    @State private var scanError: String? = nil
    @State private var hasScanned: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Scan Android QR Code")
                    .font(.title2.bold())
                Spacer()
                Button("Close") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding([.top, .horizontal])

            Text("Hold your Android phone's UniBridge QR code in front of your Mac's camera.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            ZStack {
                MacCameraViewfinder { qrString in
                    DispatchQueue.main.async {
                        guard !hasScanned else { return }
                        hasScanned = true
                        let success = p2pClient.connectViaQRPayload(qrString)
                        if success {
                            isPresented = false
                        } else {
                            scanError = "QR payload detected but invalid connection data."
                            hasScanned = false
                        }
                    }
                }
                .frame(width: 440, height: 320)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor, lineWidth: 2)
                )

                // Target box overlay
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 3, dash: [10, 5]))
                    .frame(width: 220, height: 220)
            }

            if let error = scanError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Spacer()
        }
        .frame(width: 480, height: 440)
    }
}

/**
 * -----------------------------------------------------------------------------
 * MacCameraViewfinder: Real-Time AVCaptureSession + CoreImage QR Decoder
 * -----------------------------------------------------------------------------
 */
struct MacCameraViewfinder: NSViewRepresentable {
    var onQRCodeDetected: @Sendable (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onQRCodeDetected: onQRCodeDetected)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true

        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            return view
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(context.coordinator, queue: DispatchQueue(label: "qr.camera.processing"))

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer = previewLayer

        context.coordinator.previewLayer = previewLayer
        context.coordinator.session = session

        let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let previewLayer = context.coordinator.previewLayer {
            previewLayer.frame = nsView.bounds
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.session?.stopRunning()
    }

    final class Coordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        let onQRCodeDetected: @Sendable (String) -> Void
        var previewLayer: AVCaptureVideoPreviewLayer?
        var session: AVCaptureSession?
        private let qrDetector: CIDetector? = {
            let context = CIContext()
            return CIDetector(ofType: CIDetectorTypeQRCode, context: context, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        }()
        private var lastScanTime: Date = Date.distantPast

        init(onQRCodeDetected: @escaping @Sendable (String) -> Void) {
            self.onQRCodeDetected = onQRCodeDetected
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            let now = Date()
            guard now.timeIntervalSince(lastScanTime) > 0.25 else { return }
            lastScanTime = now

            guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ciImage = CIImage(cvImageBuffer: imageBuffer)

            guard let detector = qrDetector else { return }
            let features = detector.features(in: ciImage)
            for feature in features {
                if let qrFeature = feature as? CIQRCodeFeature, let message = qrFeature.messageString, !message.isEmpty {
                    let callback = self.onQRCodeDetected
                    DispatchQueue.main.async {
                        callback(message)
                    }
                    return
                }
            }
        }
    }
}

// =============================================================================
// Scope 6: Floating Picture-in-Picture Webcam Panel & FaceTime Integration
// =============================================================================

/**
 * -----------------------------------------------------------------------------
 * FloatingCameraManager: Always-On-Top Floating Webcam Window for FaceTime / Zoom
 * -----------------------------------------------------------------------------
 * WHAT IT DOES: Manages an independent NSPanel window displaying the live Android camera feed.
 * HOW IT DOES IT:
 *   - Configures `NSPanel` with `.floating` window level so it stays visible over FaceTime.
 *   - Sets `isMovableByWindowBackground = true` and `.resizable`.
 *   - Hosts `FloatingCameraPiPView` with SwiftUI.
 * WHY IT DOES IT: Allows users on native FaceTime calls, Zoom meetings, or Google Meet
 *                 to monitor and control their phone's camera feed directly over their call.
 * -----------------------------------------------------------------------------
 */
@MainActor
final class FloatingCameraManager {
    static let shared = FloatingCameraManager()
    private var panel: NSPanel?

    func toggle(client: MacP2PClient) {
        if let p = panel, p.isVisible {
            p.orderOut(nil)
            panel = nil
            return
        }

        let p = NSPanel(
            contentRect: NSRect(x: 200, y: 300, width: 340, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        p.title = "UniBridge Camera • PiP"
        p.level = .floating
        p.isFloatingPanel = true
        p.isMovableByWindowBackground = true
        p.contentView = NSHostingView(rootView: FloatingCameraPiPView(p2pClient: client))
        p.makeKeyAndOrderFront(nil)
        self.panel = p
    }
}

/**
 * -----------------------------------------------------------------------------
 * FloatingCameraPiPView: Lightweight Picture-in-Picture Webcam Viewer
 * -----------------------------------------------------------------------------
 * WHAT IT DOES: Renders live camera frame with Flip button in a compact floating HUD.
 * HOW IT DOES IT: Subscribes to `p2pClient.latestCameraFrame` and provides quick-flip control.
 * WHY IT DOES IT: Provides an unobtrusive video monitor during live FaceTime calls.
 * -----------------------------------------------------------------------------
 */
struct FloatingCameraPiPView: View {
    @ObservedObject var p2pClient: MacP2PClient

    var body: some View {
        ZStack {
            Color.black

            if let frame = p2pClient.latestCameraFrame {
                Image(nsImage: frame)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(8)
            } else {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for camera frame...")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }

            VStack {
                HStack {
                    Text(p2pClient.currentCameraLens == "FRONT" ? "🤳 FRONT" : "📷 BACK")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.65))
                        .cornerRadius(6)

                    Spacer()

                    Button {
                        p2pClient.toggleCameraLens()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white)
                            .padding(6)
                            .background(Color.black.opacity(0.65))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(p2pClient.isCameraSwitching)
                    .help("Flip Camera Lens")
                }
                .padding(10)

                Spacer()
            }
        }
        .frame(minWidth: 240, minHeight: 320)
    }
}

/**
 * -----------------------------------------------------------------------------
 * FaceTimeIntegrationGuideSheet: macOS FaceTime & Virtual Camera Guide
 * -----------------------------------------------------------------------------
 * WHAT IT DOES: Explains how to use the Android phone camera during Apple FaceTime calls.
 * HOW IT DOES IT: Displays a clean sheet explaining Picture-in-Picture mode, FaceTime Screen Sharing,
 *                 and OBS Virtual Camera CoreMediaIO extension setup.
 * WHY IT DOES IT: Answers user questions on why Apple FaceTime restricts third-party webcams
 *                 and provides actionable, 1-click workarounds to use Android video in calls.
 * -----------------------------------------------------------------------------
 */
struct FaceTimeIntegrationGuideSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject var p2pClient: MacP2PClient

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "video.badge.checkmark")
                    .font(.system(size: 32))
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Using Phone Camera with Apple FaceTime")
                        .font(.title2.bold())
                    Text("Apple Continuity Camera & Video Conferencing Guide")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.defaultAction)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // Method 1: Floating PiP Window (Recommended)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "pip.fill")
                                .foregroundColor(.cyan)
                            Text("1. Always-on-Top Floating Camera (Recommended)")
                                .font(.headline)
                        }
                        Text("Click the **Picture-in-Picture** button in UniBridge to detach a floating webcam window that stays pinned on top of your FaceTime call, Zoom, or Google Meet. You can move it next to your call window and flip Front/Back lenses anytime.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button {
                            FloatingCameraManager.shared.toggle(client: p2pClient)
                            isPresented = false
                        } label: {
                            Label("Open Floating PiP Camera Window", systemImage: "pip.enter")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(12)

                    // Method 2: Share Screen in FaceTime
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "rectangle.inset.filled.and.cursorarrow")
                                .foregroundColor(.green)
                            Text("2. Share Camera View in FaceTime Call")
                                .font(.headline)
                        }
                        Text("While on a FaceTime call on your Mac, click the **Share Screen** button in FaceTime's toolbar, choose **Window**, and select this UniBridge FaceTime Camera window. All call participants will see your high-resolution phone camera stream in real time.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(12)

                    // Method 3: System Camera Extension (OBS Virtual Cam)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "camera.viewfinder")
                                .foregroundColor(.purple)
                            Text("3. Virtual Webcam in FaceTime Video Menu")
                                .font(.headline)
                        }
                        Text("Apple's macOS FaceTime app enforces sandboxed camera access. To select your phone as a system webcam inside FaceTime's **Video** menu, enable the **OBS Virtual Camera** system extension in **System Settings > General > Login Items & Extensions > Camera Extensions**.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("Open Camera Extensions in System Settings", systemImage: "gearshape.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(12)

                    // Method 4: In-Call Camera Switching Guide (FaceTime, WhatsApp, Teams, Google Meet)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath.camera.fill")
                                .foregroundColor(.orange)
                            Text("4. In-Call Camera Switching (FaceTime, WhatsApp, Teams, Meet)")
                                .font(.headline)
                        }

                        Text("Switch cameras anytime during a call. Your Android camera appears in these menus as **OBS Virtual Camera** once option 3 is set up; your Mac's own camera is **FaceTime HD Camera**:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 6) {
                                Text("• **Google Meet**:")
                                    .font(.caption)
                                Text("Click **More options (⋮)** → **Settings (⚙️)** → **Video** → Select camera from dropdown.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            HStack(alignment: .top, spacing: 6) {
                                Text("• **Microsoft Teams**:")
                                    .font(.caption)
                                Text("Click **More (...)** → **Device settings** → **Video settings** → Change **Camera**.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            HStack(alignment: .top, spacing: 6) {
                                Text("• **WhatsApp Desktop**:")
                                    .font(.caption)
                                Text("Click **Settings** → **Audio & Video** → Camera dropdown, or the in-call camera switcher.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            HStack(alignment: .top, spacing: 6) {
                                Text("• **Apple FaceTime**:")
                                    .font(.caption)
                                Text("In top macOS menu bar, click **Video** → **Camera** → Select camera.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(10)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)

                        Text("💡 **Instant Lens Flip (Front ⇄ Back)**: While in any video call, toggle between Selfie and 4K Main lenses without hanging up! Tap **`🔄 Switch Lens`** on your Android screen or click **Flip Lens** in UniBridge on Mac.")
                            .font(.caption)
                            .foregroundColor(.cyan)
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(12)
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(24)
        .frame(width: 580, height: 560)
    }
}
