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
 *   Acts as the SwiftUI `@main` lifecycle orchestrator for LinkMyMac on macOS.
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

        #if DEBUG
        if let mode = MacP2PClient.previewMode { // design checks: sample data, no network
            MacP2PClient.shared.loadPreviewData(paired: mode != "pairing")
            if let look = ProcessInfo.processInfo.environment["LINKMYMAC_PREVIEW_APPEARANCE"] {
                NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
            }
            if let path = ProcessInfo.processInfo.environment["LINKMYMAC_PREVIEW_SNAPSHOT"] {
                Task { @MainActor in // render our own window to a PNG (needs no screen-recording permission), then quit
                    try? await Task.sleep(for: .seconds(2.5))
                    guard let window = NSApp.windows.filter(\.isVisible).max(by: { $0.frame.width < $1.frame.width }),
                          let view = window.contentView?.superview ?? window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    exit(0)
                }
            }
            return
        }
        #endif

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
        WindowGroup("LinkMyMac") {
            DashboardView(p2pClient: p2pClient)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .defaultSize(width: 1200, height: 760)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))

        MenuBarExtra("LinkMyMac", systemImage: p2pClient.connectedDeviceName != nil ? "iphone.radiowaves.left.and.right" : "iphone.slash") {
            VStack(alignment: .leading, spacing: 8) {
                Text(p2pClient.connectedDeviceName ?? "No phone connected")
                    .font(.headline)

                Text("Status: \(p2pClient.connectionState)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let battery = p2pClient.remoteBatteryPercent {
                    Text("Phone battery: \(battery)%")
                        .font(.caption)
                }

                Divider()

                Button("Connect over USB (127.0.0.1:8765)") {
                    p2pClient.connectDirect(host: "127.0.0.1", port: 8765)
                }

                Button("Refresh Photos and Videos") {
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

                Button("Quit LinkMyMac") {
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
extension DashboardTab {
    /// Overview, or `LINKMYMAC_PREVIEW_TAB=<case>` in debug builds (design checks).
    static var initial: DashboardTab {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["LINKMYMAC_PREVIEW_TAB"],
           let tab = allCases.first(where: { "\($0)" == raw }) { return tab }
        #endif
        return .overview
    }
}

enum DashboardTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case notifications = "Notifications"
    case photos = "Photos"
    case videos = "Videos"
    case files = "Files"
    case messages = "Messages"
    case calls = "Calls"
    case phoneScreen = "Phone Screen"
    case camera = "Camera"
    case clipboard = "Clipboard"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .notifications: return "bell"
        case .photos: return "photo"
        case .videos: return "video"
        case .files: return "folder"
        case .messages: return "message"
        case .calls: return "phone"
        case .phoneScreen: return "iphone"
        case .camera: return "camera"
        case .clipboard: return "clipboard"
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
    @State private var selectedTab: DashboardTab = .initial

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
    @State private var showQRPairing = false
    @State private var selectedMediaID: String?

    var body: some View {
        NavigationSplitView {
            SidebarView(client: p2pClient, phone: p2pClient.phone, selection: $selectedTab)
                .toolbar(removing: .sidebarToggle)
                .navigationSplitViewColumnWidth(min: 240, ideal: 252, max: 300)
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
        }
        .onChange(of: selectedTab) { // each section starts unfiltered, nothing selected
            photoSearchText = ""
            selectedMediaID = nil
        }
        .sheet(isPresented: $showQRPairing) {
            qrPairingSheet
        }
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
            itemPendingDeletion?.isVideo == true ? "Delete this video from your phone?" : "Delete this photo from your phone?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete from Phone", role: .destructive) {
                if let item = itemPendingDeletion {
                    p2pClient.deleteMediaItem(mediaId: item.id)
                    itemPendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {
                itemPendingDeletion = nil
            }
        } message: {
            Text("It’s removed from your phone’s storage for good.")
        }
    }

    // =========================================================================
    // Detail: the pairing screen until a phone is paired, then the selected tab
    // =========================================================================
    @ViewBuilder
    private var detailContent: some View {
        if !p2pClient.isPaired {
            PairingScreen(client: p2pClient, code: $pairingCodeInput, submit: submitPairingCode, showQR: { showQRPairing = true })
                .navigationTitle("Pair a phone")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Scan QR code") { showQRPairing = true }.buttonStyle(.lmSecondary)
                    }
                }
        } else {
            switch selectedTab {
            case .overview:
                OverviewScreen(client: p2pClient, phone: p2pClient.phone) { selectedTab = $0 }
                    .navigationTitle("Overview")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            HStack(spacing: 10) {
                                StatusChip(tone: .success, label: p2pClient.isWirelessConnection ? "Connected over Wi‑Fi" : "Connected over USB")
                                Button("Send a file") { chooseFilesAndSend(to: p2pClient) }.buttonStyle(.lmSecondary)
                            }
                        }
                    }
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
            }
        }
    }

    /// QR code and manual-address pairing, opened from the pairing screen.
    private var qrPairingSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Other ways to connect").font(.lmTitle).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("Done") { showQRPairing = false }.buttonStyle(.lmSecondary).keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Hairline()
            qrPairingDetailView
        }
        .frame(width: 660, height: 640)
        .background(Theme.canvas)
    }

    // =========================================================================
    // Scope 1: Notifications Detail View
    // =========================================================================
    private var notificationsDetailView: some View {
        Group {
            if filteredNotifications.isEmpty {
                EmptyStateView(symbol: "bell.slash",
                               title: notificationSearchText.isEmpty ? "No notifications" : "No matches",
                               message: notificationSearchText.isEmpty
                                   ? "Notifications from your phone’s apps show up here as they arrive."
                                   : "Nothing matches “\(notificationSearchText)”.",
                               actionTitle: notificationSearchText.isEmpty ? "Sync from phone" : nil,
                               action: notificationSearchText.isEmpty ? { p2pClient.requestNotificationSync() } : nil)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(notificationGroups.enumerated()), id: \.element.label) { index, group in
                            HStack {
                                SectionLabel(text: group.label)
                                Spacer()
                                if index == 0 {
                                    Text("Replies and buttons run on your phone").font(.lmCaption).foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .padding(.top, index == 0 ? 0 : 8)
                            ForEach(group.items) { notificationCard($0) }
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 20)
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationSubtitle("\(p2pClient.notifications.count) from your phone")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                LMSearchField(placeholder: "Filter notifications", text: $notificationSearchText, width: 200)
                Button("Clear all on phone") { p2pClient.clearAllNotificationsOnAndroid() }
                    .buttonStyle(.lmSecondary)
                    .disabled(p2pClient.notifications.isEmpty)
                    .help("Dismiss every clearable notification on your phone")
                IconButton(symbol: "arrow.clockwise", help: "Sync from phone") { p2pClient.requestNotificationSync() }
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

    /// Notifications in arrival order, split into Today / Yesterday / weekday groups.
    private var notificationGroups: [(label: String, items: [MirroredNotification])] {
        var groups: [(label: String, items: [MirroredNotification])] = []
        for n in filteredNotifications {
            let label = dayLabel(n.postTimeMs)
            if groups.last?.label == label { groups[groups.count - 1].items.append(n) } else { groups.append((label, [n])) }
        }
        return groups
    }

    private func dayLabel(_ postTimeMs: Int64) -> String {
        guard postTimeMs > 0 else { return "Earlier" }
        let date = Date(timeIntervalSince1970: TimeInterval(postTimeMs) / 1000)
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.wide).day().month())
    }

    /// One mirrored notification (Figma Mac/Notification card): app icon, text, the app's
    /// own buttons, inline reply, dismiss. Buttons and replies run on the phone.
    private func notificationCard(_ notif: MirroredNotification) -> some View {
        let reply = notif.actions.first(where: { $0.supportsInlineReply })
        let buttons = notif.actions.filter { !$0.supportsInlineReply }
        return HStack(alignment: .top, spacing: 14) {
            NotificationAppIcon(data: notif.appIconData, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(notif.appName).font(.lmCaption).foregroundStyle(Theme.textSecondary)
                    if notif.postTimeMs > 0 {
                        Text("·").font(.lmCaption).foregroundStyle(Theme.textTertiary)
                        Text(formatNotificationTime(notif.postTimeMs)).font(.lmCaption).foregroundStyle(Theme.textTertiary)
                    }
                }
                if !notif.title.isEmpty {
                    Text(notif.title).font(.lmHeadline).foregroundStyle(Theme.textPrimary)
                }
                if !notif.body.isEmpty {
                    Text(notif.body).font(.lmBody).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                if !buttons.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(buttons, id: \.id) { action in
                            Button(action.title) {
                                p2pClient.sendNotificationReply(notificationKey: notif.id, actionId: action.id, replyText: "")
                            }
                            .buttonStyle(.lmSecondary)
                        }
                    }
                    .padding(.top, 8)
                }
                if let reply {
                    HStack(spacing: 8) {
                        TextField(reply.replyPlaceholder.isEmpty ? "Reply" : reply.replyPlaceholder,
                                  text: Binding(get: { replyTexts[notif.id] ?? "" }, set: { replyTexts[notif.id] = $0 }))
                            .textFieldStyle(LMTextFieldStyle())
                            .onSubmit { submitReply(for: notif, action: reply) }
                        Button("Send") { submitReply(for: notif, action: reply) }
                            .buttonStyle(.lmPrimary)
                            .disabled((replyTexts[notif.id] ?? "").isEmpty)
                    }
                    .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(symbol: "xmark", help: "Dismiss on your Mac and phone", tint: Theme.textTertiary) {
                p2pClient.dismissNotificationOnAndroid(key: notif.id)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.borderSubtle))
        .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
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
    // Photos and Videos (Figma: Mac · Photos, Mac · Videos). Paged separately.
    // =========================================================================
    private func mediaGalleryView(_ kind: MediaKind) -> some View {
        let isVideos = kind == .videos
        let items = filteredMediaItems(kind)
        let loaded = p2pClient.mediaItems(kind).count
        let total = p2pClient.mediaTotals[kind]
        let noun = isVideos ? "video" : "photo"
        let selected = items.first { $0.id == selectedMediaID }
        return Group {
            if items.isEmpty {
                EmptyStateView(symbol: isVideos ? "video" : "photo",
                               title: photoSearchText.isEmpty ? "No \(noun)s yet" : "No matches",
                               message: photoSearchText.isEmpty
                                   ? "Sync to browse the \(noun)s on your phone. Nothing is copied until you save it."
                                   : "Nothing matches “\(photoSearchText)”.",
                               actionTitle: photoSearchText.isEmpty ? "Sync \(noun)s" : nil,
                               action: photoSearchText.isEmpty ? { p2pClient.syncAllGallery(kind) } : nil)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if isVideos, let playing = selected ?? items.first {
                            nowPlaying(playing)
                        }
                        if groupMediaByFolder {
                            ForEach(mediaFolders(items)) { folder in
                                let key = folderKey(kind, folder)
                                let open = !collapsedFolders.contains(key)
                                VStack(alignment: .leading, spacing: 10) {
                                    FolderHeaderRow(name: folder.name,
                                                    count: "\(folder.items.count) \(noun)\(folder.items.count == 1 ? "" : "s")",
                                                    path: folder.path, expanded: open) {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            if open { collapsedFolders.insert(key) } else { collapsedFolders.remove(key) }
                                        }
                                    }
                                    .help(open ? "Collapse folder" : "Expand folder")
                                    if open { mediaGrid(folder.items, videos: isVideos) }
                                }
                            }
                        } else {
                            mediaGrid(items, videos: isVideos)
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 20)
                    .padding(.bottom, !isVideos && selected != nil ? 64 : 0) // room for the floating bar
                }
                .overlay(alignment: .bottom) {
                    if !isVideos, let selected {
                        selectionBar(selected).padding(.bottom, 18)
                    }
                }
            }
        }
        .navigationTitle(isVideos ? "Videos" : "Photos")
        .navigationSubtitle(gallerySubtitle(kind, loaded: loaded, total: total, noun: noun))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Group", selection: $groupMediaByFolder) {
                    Text("All").tag(false)
                    Text("By folder").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Group by the folder each item is in on the phone (Camera, Screenshots…)")
                LMSearchField(placeholder: isVideos ? "Search videos" : "Search photos", text: $photoSearchText, width: 180)
                if p2pClient.syncingKind == kind {
                    ProgressView().controlSize(.small).help("Syncing…")
                } else {
                    IconButton(symbol: "arrow.clockwise", help: "Sync all \(noun)s from your phone") { p2pClient.syncAllGallery(kind) }
                        .disabled(p2pClient.syncingKind != nil) // one sync at a time
                }
            }
        }
    }

    private func gallerySubtitle(_ kind: MediaKind, loaded: Int, total: Int?, noun: String) -> String {
        if p2pClient.syncingKind == kind, let total { return "Syncing \(loaded.formatted()) of \(total.formatted())…" }
        guard let total else { return loaded > 0 ? "\(loaded.formatted()) \(noun)s" : "" }
        return loaded < total ? "\(loaded.formatted()) of \(total.formatted()) \(noun)s loaded" : "\(total.formatted()) \(noun)s"
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

    private func filteredMediaItems(_ kind: MediaKind) -> [RemoteMediaItem] {
        let items = p2pClient.mediaItems(kind)
        guard !photoSearchText.isEmpty else { return items }
        let query = photoSearchText.lowercased()
        return items.filter { $0.displayName.lowercased().contains(query) }
    }

    private func mediaGrid(_ items: [RemoteMediaItem], videos: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: videos ? 168 : 132, maximum: videos ? 240 : 180), spacing: videos ? 12 : 8)],
                  spacing: videos ? 12 : 8) {
            ForEach(items) { mediaTile($0) }
        }
    }

    /// Thumbnail tile (Figma Mac/Media tile). Click selects, double-click opens.
    private func mediaTile(_ item: RemoteMediaItem) -> some View {
        let selected = selectedMediaID == item.id
        return Color.clear
            .aspectRatio(item.isVideo ? 16.0 / 9.0 : 1, contentMode: .fit)
            .overlay {
                if let data = item.thumbnailData, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: item.isVideo ? "video" : "photo").font(.system(size: 22)).foregroundStyle(Theme.textTertiary)
                }
            }
            .background(Theme.surfaceMuted)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    Label(formatDuration(item.durationMs), systemImage: "play.fill")
                        .font(.lmCaption).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.55)))
                        .padding(6)
                }
            }
            .overlay(alignment: .bottom) {
                if let download = mediaDownload(for: item) {
                    ProgressView(value: Double(download.bytesTransferred), total: Double(max(download.totalBytes, 1)))
                        .tint(.white).padding(8)
                }
            }
            .overlay(alignment: .topLeading) {
                if p2pClient.localFileURL(for: item.id) != nil {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 14))
                        .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.45))
                        .padding(6).help("Saved on this Mac")
                }
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.brand, lineWidth: 3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.onBrand)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.brand))
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .padding(8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                previewAutoplay = item.isVideo
                previewMediaItem = item
            }
            .onTapGesture { selectedMediaID = selected ? nil : item.id }
            .contextMenu {
                Button("Open") { previewAutoplay = false; previewMediaItem = item }
                Button("Save to Mac") { p2pClient.downloadFullResolutionMedia(mediaId: item.id) }
                Button("Share…") { shareMediaItem(item) }
                Divider()
                Button("Delete from Phone…", role: .destructive) { itemPendingDeletion = item; showDeleteConfirmation = true }
            }
            .help(item.displayName)
    }

    /// Floating actions for the selected photo (Figma: Selection bar).
    private func selectionBar(_ item: RemoteMediaItem) -> some View {
        HStack(spacing: 4) {
            Text("1 selected").font(.lmHeadline).foregroundStyle(Theme.textPrimary).padding(.leading, 10)
            Rectangle().fill(Theme.textTertiary.opacity(0.35)).frame(width: 1, height: 20).padding(.horizontal, 6)
            barButton("arrow.down.to.line", "Save to Mac") { p2pClient.downloadFullResolutionMedia(mediaId: item.id) }
            barButton("square.and.arrow.up", "Share…") { shareMediaItem(item) }
            barButton("trash", "Delete from phone", tint: Theme.danger) {
                itemPendingDeletion = item
                showDeleteConfirmation = true
            }
        }
        .padding(6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.borderSubtle))
        .shadow(color: .black.opacity(0.16), radius: 16, y: 12)
    }

    private func barButton(_ symbol: String, _ title: String, tint: Color = Theme.textPrimary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.lmBody).foregroundStyle(tint)
                .padding(.horizontal, 10).frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Selected video: inline streaming player plus details (Figma: Now playing + Details).
    private func nowPlaying(_ item: RemoteMediaItem) -> some View {
        HStack(alignment: .top, spacing: 16) {
            MediaPlayerPanel(item: item, client: p2pClient).id(item.id)
            VStack(alignment: .leading, spacing: 12) {
                Text(item.displayName).font(.lmTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                KeyValueRow(key: "Duration", value: formatDuration(item.durationMs))
                KeyValueRow(key: "Size", value: formatBytes(item.sizeBytes))
                KeyValueRow(key: "Resolution", value: "\(item.width) × \(item.height)")
                KeyValueRow(key: "Folder", value: item.folderPath.isEmpty ? "—" : item.folderPath)
                VStack(spacing: 8) {
                    Button("Save to Mac") { p2pClient.downloadFullResolutionMedia(mediaId: item.id) }
                        .buttonStyle(LMButtonStyle(kind: .secondary, fullWidth: true))
                        .disabled(mediaDownload(for: item) != nil || p2pClient.localFileURL(for: item.id) != nil)
                    Button("Share…") { shareMediaItem(item) }
                        .buttonStyle(LMButtonStyle(kind: .secondary, fullWidth: true))
                    Button("Delete from phone") { itemPendingDeletion = item; showDeleteConfirmation = true }
                        .buttonStyle(LMButtonStyle(kind: .destructive, fullWidth: true))
                }
                Spacer(minLength: 0)
                Text("Streams in chunks, so only the parts you watch are loaded.").font(.lmCaption).foregroundStyle(Theme.textTertiary)
            }
            .frame(width: 240)
            .frame(maxHeight: .infinity, alignment: .top)
            .lmCard(padding: 18)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // =========================================================================
    // Camera (Figma: Mac · Camera): live view of the phone's camera
    // =========================================================================
    private var cameraDetailView: some View {
        HStack(alignment: .center, spacing: 20) {
            cameraPreview.frame(maxWidth: .infinity)
            cameraPanel.frame(width: 280)
        }
        .padding(.horizontal, 24).padding(.vertical, 20)
        .frame(maxHeight: .infinity)
        .navigationTitle("Camera")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if p2pClient.isCameraStreaming {
                    StatusChip(tone: .success, label: "Live · \(lensName(p2pClient.currentCameraLens).lowercased()) camera")
                    Button("Stop camera") { p2pClient.stopCameraStream() }.buttonStyle(.lmSecondary)
                } else {
                    Button("Start camera") { p2pClient.startCameraStream(lens: selectedLens) }.buttonStyle(.lmPrimary)
                }
            }
        }
    }

    private var cameraPreview: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.09)
            if let frame = p2pClient.latestCameraFrame {
                Image(nsImage: frame).resizable().scaledToFit()
                    .rotation3DEffect(.degrees(isCameraFlipping ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                    .animation(.spring(response: 0.45, dampingFraction: 0.7), value: isCameraFlipping)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash").font(.system(size: 34, weight: .light)).foregroundStyle(.white.opacity(0.5))
                    Text(p2pClient.isCameraStreaming ? "Opening your phone’s camera…" : "Camera is off")
                        .font(.lmTitle).foregroundStyle(.white)
                    Text("See your phone’s camera here, then share it into a call.")
                        .font(.lmCallout).foregroundStyle(.white.opacity(0.6))
                    if !p2pClient.isCameraStreaming {
                        Button("Start camera") { p2pClient.startCameraStream(lens: selectedLens) }.buttonStyle(.lmPrimary).padding(.top, 4)
                    }
                }
            }
            VStack {
                HStack {
                    if p2pClient.isCameraStreaming {
                        cameraPill {
                            Circle().fill(Color.red).frame(width: 8, height: 8)
                            Text("LIVE · \(lensName(p2pClient.currentCameraLens)) camera")
                        }
                    }
                    Spacer()
                    if let status = snapshotStatusText {
                        cameraPill { Image(systemName: "checkmark.circle"); Text(status) }
                    } else if p2pClient.isCameraStreaming {
                        cameraPill { Image(systemName: "wifi"); Text("From \(p2pClient.connectedDeviceName ?? "your phone")") }
                    }
                }
                .padding(16)
                Spacer()
                if let frame = p2pClient.latestCameraFrame {
                    cameraControls(frame).padding(.bottom, 18)
                }
            }
            if p2pClient.isCameraSwitching {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.regular)
                    Text("Switching to the \(lensName(p2pClient.currentCameraLens).lowercased()) camera…").font(.lmHeadline).foregroundStyle(.white)
                }
                .padding(22)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.8)))
            }
            if let error = p2pClient.cameraErrorMessage {
                VStack(spacing: 10) {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.lmHeadline).foregroundStyle(.yellow)
                    Button("Try again") { p2pClient.switchCameraLens(p2pClient.currentCameraLens) }.buttonStyle(.lmPrimary)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.85)))
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func cameraPill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .font(.lmCaption).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(.black.opacity(0.45)))
    }

    /// Flip lens, snapshot, floating window (Figma: Camera controls).
    private func cameraControls(_ frame: NSImage) -> some View {
        HStack(spacing: 22) {
            roundCameraButton("arrow.triangle.2.circlepath.camera", help: "Flip camera (front ⇄ back)", busy: p2pClient.isCameraSwitching) {
                isCameraFlipping.toggle()
                p2pClient.toggleCameraLens()
                selectedLens = p2pClient.currentCameraLens
            }
            .disabled(p2pClient.isCameraSwitching)
            Button { takeSnapshot(from: frame) } label: {
                Circle().fill(.white).frame(width: 48, height: 48)
                    .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 4).padding(-6))
            }
            .buttonStyle(.plain)
            .help("Take a snapshot (saved to Downloads)")
            roundCameraButton("pip.enter", help: "Floating window that stays over FaceTime or Zoom") {
                FloatingCameraManager.shared.toggle(client: p2pClient)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.45)))
    }

    private func roundCameraButton(_ symbol: String, help: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(.white.opacity(0.16)).frame(width: 40, height: 40)
                if busy { ProgressView().controlSize(.small) } else {
                    Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var cameraPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Lens").font(.lmHeadline).foregroundStyle(Theme.textPrimary)
                Picker("Lens", selection: Binding(
                    get: { p2pClient.currentCameraLens },
                    set: { newLens in
                        selectedLens = newLens
                        if p2pClient.isCameraStreaming { p2pClient.switchCameraLens(newLens) }
                    }
                )) {
                    Text("Back").tag("BACK")
                    Text("Front").tag("FRONT")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                .disabled(p2pClient.isCameraSwitching)
                Text("Switching takes a moment while your phone swaps cameras.")
                    .font(.lmCallout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lmCard(padding: 18)
            VStack(alignment: .leading, spacing: 14) {
                Text("Use it in a call").font(.lmHeadline).foregroundStyle(Theme.textPrimary)
                callOption(1, kicker: "Recommended", title: "Floating window",
                           detail: "Stays on top of FaceTime, Zoom or Meet. Share that window in the call.") {
                    Button("Open floating window") { FloatingCameraManager.shared.toggle(client: p2pClient) }.buttonStyle(.lmSecondary)
                }
                callOption(2, kicker: nil, title: "Pick it as a webcam",
                           detail: "Needs OBS Virtual Camera. Then choose “OBS Virtual Camera” in the call’s camera menu.") {
                    Button { showFaceTimeGuide = true } label: { Text("Setup guide").font(.lmCallout).foregroundStyle(Theme.brand) }
                        .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .lmCard(padding: 18)
        }
    }

    private func callOption<Extra: View>(_ number: Int, kicker: String?, title: String, detail: String, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.lmCaption).foregroundStyle(Theme.onBrandSoft)
                .frame(width: 22, height: 22).background(Circle().fill(Theme.brandSoft))
            VStack(alignment: .leading, spacing: 4) {
                if let kicker { SectionLabel(text: kicker, color: Theme.brand) }
                Text(title).font(.lmHeadline).foregroundStyle(Theme.textPrimary)
                Text(detail).font(.lmCallout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                extra().padding(.top, 2)
            }
        }
    }

    private func lensName(_ lens: String) -> String { lens == "FRONT" ? "Front" : "Back" }

    private func takeSnapshot(from frame: NSImage) {
        if let tiff = frame.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let jpeg = bitmap.representation(using: .jpeg, properties: [:]) {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let url = downloads.appendingPathComponent("LinkMyMac Snapshot \(Int(Date().timeIntervalSince1970)).jpg")
            try? jpeg.write(to: url)
            snapshotStatusText = "Saved to Downloads"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                snapshotStatusText = nil
            }
        }
    }

    // =========================================================================
    // Clipboard (Figma: Mac · Clipboard)
    // =========================================================================
    private var clipboardDetailView: some View {
        let macText = macClipboardText
        let phoneText = p2pClient.lastSyncedClipboardText.isEmpty ? nil : p2pClient.lastSyncedClipboardText
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    clipCard(symbol: "laptopcomputer", who: "This Mac", note: "Copied with ⌘C",
                             text: macText, placeholder: "Your Mac’s clipboard is empty.") {
                        Button("Send again") { if let macText { p2pClient.sendClipboardText(macText) } }
                            .buttonStyle(.lmPrimary).disabled(macText == nil)
                        Text("Copying here sends it automatically").font(.lmCaption).foregroundStyle(Theme.textTertiary)
                    }
                    clipCard(symbol: "iphone", who: p2pClient.connectedDeviceName ?? "Your phone", note: "Last copied there",
                             text: phoneText, placeholder: "Nothing copied on your phone yet.") {
                        Button("Copy to Mac") {
                            guard let phoneText else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(phoneText, forType: .string)
                        }
                        .buttonStyle(.lmSecondary).disabled(phoneText == nil)
                        Text("Then paste with ⌘V").font(.lmCaption).foregroundStyle(Theme.textTertiary)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Send text to your phone’s clipboard").font(.lmHeadline).foregroundStyle(Theme.textPrimary)
                    TextField("Type or paste text or a link…", text: $customClipboardInput, axis: .vertical)
                        .textFieldStyle(.plain).font(.lmBody).lineLimit(3...6)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.borderStrong))
                    HStack {
                        Text("Text only. Send photos and other files from Files.").font(.lmCaption).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Button("Send to phone") {
                            guard !customClipboardInput.isEmpty else { return }
                            p2pClient.sendClipboardText(customClipboardInput)
                            customClipboardInput = ""
                        }
                        .buttonStyle(.lmPrimary)
                        .disabled(customClipboardInput.isEmpty)
                    }
                }
                .lmCard(padding: 18)
                if !p2pClient.clipboardSyncHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recent").font(.lmHeadline).foregroundStyle(Theme.textPrimary)
                        ForEach(p2pClient.clipboardSyncHistory, id: \.self) { item in
                            HStack(spacing: 10) {
                                Text(item).font(.lmBody).foregroundStyle(Theme.textSecondary).lineLimit(1)
                                Spacer(minLength: 8)
                                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item, forType: .string) } label: {
                                    Text("Copy").font(.lmCallout).foregroundStyle(Theme.brand)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lmCard(padding: 18)
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.warning)
                    Text("On Android 10 and later, apps can only read the clipboard while they’re open. After copying on your phone, open LinkMyMac to send it here. Mac → phone works anytime.")
                        .font(.lmCallout).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.warningSoft))
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
        }
        .navigationTitle("Clipboard")
        .navigationSubtitle("Copy on one, paste on the other")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { StatusChip(tone: .success, label: "Syncing text") }
        }
    }

    /// The Mac's clipboard text (sample text in design-preview runs, so checks never show real data).
    private var macClipboardText: String? {
        #if DEBUG
        if MacP2PClient.previewMode != nil { return "Meet at the café on the 2nd floor — table by the window." }
        #endif
        return NSPasteboard.general.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
    }

    private func clipCard<Footer: View>(symbol: String, who: String, note: String, text: String?, placeholder: String,
                                        @ViewBuilder footer: () -> Footer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, size: 32, radius: 9, iconSize: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(who).font(.lmHeadline).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(note).font(.lmCaption).foregroundStyle(Theme.textTertiary)
                }
            }
            Text(text ?? placeholder)
                .font(.lmBody).foregroundStyle(text == nil ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surfaceMuted))
                .textSelection(.enabled)
            HStack(spacing: 10) { footer() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lmCard(padding: 18)
    }

    // =========================================================================
    // Other ways to connect: QR code, pairing text, address (sheet from Pair a phone)
    // =========================================================================
    private var qrPairingDetailView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let peer = p2pClient.discoveredPeers.first, p2pClient.connectedDeviceName == nil {
                    HStack(spacing: 12) {
                        IconTile(symbol: "wifi", size: 32, radius: 9, iconSize: 14)
                        Text("Found \(peer.name) on your Wi‑Fi").font(.lmHeadline).foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Button("Connect") { p2pClient.connect(to: peer) }.buttonStyle(.lmPrimary)
                    }
                    .lmCard(padding: 14)
                }
                connectOption(symbol: "qrcode.viewfinder", title: "Scan the QR code",
                              detail: "Hold the QR code in LinkMyMac on your phone up to this Mac’s camera, or pick a screenshot of it.") {
                    HStack(spacing: 8) {
                        Button("Open camera scanner") { isShowingQRScanner = true }.buttonStyle(.lmPrimary)
                        Button("Choose image…") { selectAndScanQRImage() }.buttonStyle(.lmSecondary)
                    }
                }
                connectOption(symbol: "doc.text", title: "Paste the pairing text",
                              detail: "The text version of the QR code, copied from your phone.") {
                    HStack(spacing: 8) {
                        TextField("Paste pairing text", text: $qrPasteString).textFieldStyle(LMTextFieldStyle())
                        Button("Connect") {
                            let ok = p2pClient.connectViaQRPayload(qrPasteString)
                            qrStatusMessage = ok ? "Connecting…" : "That doesn’t look like LinkMyMac pairing text."
                        }
                        .buttonStyle(.lmPrimary)
                        .disabled(qrPasteString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let status = qrStatusMessage {
                        Text(status).font(.lmCallout).foregroundStyle(Theme.textSecondary)
                    }
                }
                connectOption(symbol: "network", title: "Connect by address",
                              detail: "Use the phone’s IP address, or a USB cable with “adb forward tcp:8765 tcp:8765”.") {
                    HStack(spacing: 8) {
                        TextField("IP address", text: $manualHost).textFieldStyle(LMTextFieldStyle()).frame(width: 150)
                        TextField("Port", text: $manualPort).textFieldStyle(LMTextFieldStyle()).frame(width: 70)
                        Button("Connect") { p2pClient.connectDirect(host: manualHost, port: UInt16(manualPort) ?? 8765) }
                            .buttonStyle(.lmSecondary)
                        Button("Use USB") { p2pClient.connectDirect(host: "127.0.0.1", port: 8765) }
                            .buttonStyle(.lmPrimary)
                    }
                }
            }
            .padding(20)
        }
    }

    private func connectOption<Content: View>(symbol: String, title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: symbol, size: 36, radius: 10, iconSize: 16)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.lmHeadline).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(.lmCallout).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lmCard(padding: 16)
    }

    // =========================================================================
    // Files (Figma: Mac · Files): drop zone + transfers, both directions
    // =========================================================================
    private var filesDetailView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                filesDropZone
                if !p2pClient.transfers.isEmpty {
                    HStack(spacing: 8) {
                        Text("Transfers").font(.lmTitle).tracking(-0.1).foregroundStyle(Theme.textPrimary)
                        Text(transferSummary).font(.lmCallout).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        if p2pClient.transfers.contains(where: { $0.status != .inProgress }) {
                            Button { p2pClient.clearFinishedTransfers() } label: {
                                Text("Clear finished").font(.lmCallout).foregroundStyle(Theme.brand)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(p2pClient.transfers.enumerated()), id: \.element.id) { index, transfer in
                            transferRow(transfer)
                            if index < p2pClient.transfers.count - 1 { Hairline() }
                        }
                    }
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.borderSubtle))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
        }
        .navigationTitle("Files")
        .navigationSubtitle("Send files to your phone")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                StatusChip(tone: .success, label: "\(p2pClient.connectedDeviceName ?? "Phone") · \(p2pClient.isWirelessConnection ? "Wi‑Fi" : "USB")")
            }
        }
    }

    private var filesDropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up").font(.system(size: 22, weight: .medium)).foregroundStyle(Theme.brand)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surface))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 4)
            Text("Drop files here to send them to \(p2pClient.connectedDeviceName ?? "your phone")")
                .font(.lmTitle).tracking(-0.1).foregroundStyle(Theme.textPrimary)
            Text("They land in Download/LinkMyMac on your phone. Files you share from the phone land in Downloads.")
                .font(.lmCallout).foregroundStyle(Theme.textSecondary)
            Button("Choose Files…") { chooseFilesAndSend(to: p2pClient) }.buttonStyle(.lmPrimary).padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 210)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.brandSoft.opacity(isDropTargeted ? 0.95 : 0.55)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Theme.brand, style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.5, dash: [6, 5])))
        .dropDestination(for: URL.self) { urls, _ in
            guard p2pClient.isPaired else { return false }
            p2pClient.sendFiles(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var transferSummary: String {
        let sending = p2pClient.transfers.filter { $0.status == .inProgress }.count
        let done = p2pClient.transfers.filter { $0.status == .done }.count
        let failed = p2pClient.transfers.count - sending - done
        return [(sending, "sending"), (done, "done"), (failed, "failed")].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    /// One transfer (Figma Mac/Transfer row: Sending / Done / Failed).
    private func transferRow(_ transfer: FileTransfer) -> some View {
        let toPhone = transfer.direction == .toPhone
        let colors: (Color, Color) = {
            switch transfer.status {
            case .inProgress: return (Theme.brandSoft, Theme.brand)
            case .done: return (Theme.successSoft, Theme.success)
            case .failed: return (Theme.dangerSoft, Theme.danger)
            }
        }()
        return HStack(spacing: 14) {
            IconTile(symbol: toPhone ? "doc" : "arrow.down.doc", size: 40, radius: 10, iconSize: 17,
                     background: colors.0, foreground: colors.1)
            VStack(alignment: .leading, spacing: 6) {
                Text(transfer.name).font(.lmHeadline).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                switch transfer.status {
                case .inProgress:
                    if transfer.totalBytes > 0 {
                        ProgressView(value: Double(min(transfer.bytesTransferred, transfer.totalBytes)), total: Double(transfer.totalBytes))
                            .tint(Theme.brand)
                        Text("\(formatBytes(transfer.bytesTransferred)) of \(formatBytes(transfer.totalBytes))")
                            .font(.lmCallout).foregroundStyle(Theme.textSecondary)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(Theme.brand)
                    }
                case .done:
                    Text(toPhone ? "\(formatBytes(transfer.totalBytes)) · Saved to Download/LinkMyMac"
                                 : "\(formatBytes(transfer.bytesTransferred)) · Saved to Downloads")
                        .font(.lmCallout).foregroundStyle(Theme.textSecondary)
                case .failed(let reason):
                    Text(reason).font(.lmCallout).foregroundStyle(Theme.danger)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            switch transfer.status {
            case .inProgress:
                if transfer.totalBytes > 0 {
                    Text("\(Int(Double(transfer.bytesTransferred) / Double(transfer.totalBytes) * 100))%")
                        .font(.lmCallout).foregroundStyle(Theme.textSecondary).monospacedDigit()
                }
            case .done:
                if let url = transfer.localURL {
                    IconButton(symbol: "eye", help: "Open") { NSWorkspace.shared.open(url) }
                    IconButton(symbol: "folder", help: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } else {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.success)
                }
            case .failed:
                if toPhone, let url = transfer.localURL {
                    Button("Retry") { p2pClient.sendFiles([url]) }.buttonStyle(.lmSecondary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
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

            Text("Hold your Android phone's LinkMyMac QR code in front of your Mac's camera.")
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
        p.title = "LinkMyMac Camera"
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
                        Text("Click **Open floating window** in LinkMyMac's Camera tab to detach a floating webcam window that stays pinned on top of your FaceTime call, Zoom, or Google Meet. You can move it next to your call window and flip Front/Back lenses anytime.")
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
                        Text("While on a FaceTime call on your Mac, click the **Share Screen** button in FaceTime's toolbar, choose **Window**, and select the **LinkMyMac Camera** window. All call participants will see your high-resolution phone camera stream in real time.")
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

                        Text("💡 **Instant Lens Flip (Front ⇄ Back)**: While in any video call, toggle between Selfie and 4K Main lenses without hanging up! Tap **`🔄 Switch Lens`** on your Android screen or click the flip-camera button in LinkMyMac on your Mac.")
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
