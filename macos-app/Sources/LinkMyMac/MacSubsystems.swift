import Foundation
import AppKit
import UserNotifications
import CryptoKit

/**
 * =============================================================================
 * MacSubsystems: macOS Native System Integration Bridge
 * =============================================================================
 * WHAT IT DOES:
 *   Integrates the P2P protocol engine (`MacP2PClient`) with native macOS
 *   operating system services:
 *     1. Universal Clipboard (`NSPasteboard`): Bidirectional sync with SHA-256
 *        echo-loop prevention.
 *     2. Native Notifications (`UNUserNotificationCenter`): Native macOS banner
 *        alerts with interactive inline reply text fields and remote dismissal.
 *
 * HOW IT DOES IT:
 *   - Runs a 400ms periodic timer observing `NSPasteboard.general.changeCount`.
 *   - Hashes copied text via Apple's CryptoKit `SHA256` to detect actual content changes.
 *   - Implements `UNUserNotificationCenterDelegate` to intercept user clicks on
 *     desktop notification banners and dispatch replies over TCP.
 *   - Checks `Bundle.main.bundleIdentifier` before calling `UNUserNotificationCenter`
 *     to prevent crashes when executed as an unpackaged CLI binary.
 *
 * WHY IT DOES IT:
 *   Users expect background ecosystem bridges (like Apple Continuity / Universal
 *   Clipboard) to work seamlessly at the OS level without needing manual copy/paste
 *   windows or custom notification panels.
 * =============================================================================
 */
@MainActor
public final class MacSubsystems: NSObject, UNUserNotificationCenterDelegate {

    private let p2pClient: MacP2PClient
    private var pasteboardTimer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var lastSyncedHash: String = ""
    public private(set) var mediaManager: MacMediaManager?

    public init(p2pClient: MacP2PClient) {
        self.p2pClient = p2pClient
        super.init()
        let media = MacMediaManager(p2pClient: p2pClient)
        media.startMonitoring()
        self.mediaManager = media
        setupCallbacks()
        configureNativeNotifications()
    }

    /**
     * WHAT IT DOES:
     *   Attaches closures to `MacP2PClient` events to route incoming remote data
     *   into macOS native subsystems.
     *
     * HOW IT DOES IT:
     *   - Binds `onRemoteClipboardReceived` to `applyIncomingClipboard`.
     *   - Binds `onMirroredNotificationPosted` to `postMacOSBannerNotification`.
     *   - Uses `[weak self]` and `Task { @MainActor in }` to maintain actor isolation.
     *
     * WHY IT DOES IT:
     *   Maintains strict separation of concerns: `MacP2PClient` only understands
     *   network frames, while `MacSubsystems` owns native AppKit/UserNotifications APIs.
     */
    private func setupCallbacks() {
        p2pClient.onRemoteClipboardReceived = { [weak self] text, sha256 in
            Task { @MainActor in
                self?.applyIncomingClipboard(text: text, sha256: sha256)
            }
        }

        p2pClient.onMirroredNotificationPosted = { [weak self] item in
            Task { @MainActor in
                self?.postMacOSBannerNotification(item)
            }
        }

        p2pClient.onMediaControlCommandReceived = { [weak self] action in
            Task { @MainActor in
                self?.mediaManager?.handleCommand(action)
            }
        }

        p2pClient.onConnected = { [weak self] in
            Task { @MainActor in
                self?.mediaManager?.forceBroadcastCurrentState()
            }
        }
    }

    // =========================================================================
    // MARK: - 1. NSPasteboard Universal Clipboard Watcher
    // =========================================================================

    /**
     * WHAT IT DOES:
     *   Starts a background timer to watch the system clipboard for new copies.
     *
     * HOW IT DOES IT:
     *   Schedules a repeating 400ms timer on the main runloop calling
     *   `checkLocalPasteboardChanges()`.
     *
     * WHY IT DOES IT:
     *   macOS does not provide a system-wide push notification event for pasteboard
     *   changes; periodic inspection of `changeCount` is the sanctioned Apple pattern.
     */
    public func startClipboardMonitor() {
        lastChangeCount = NSPasteboard.general.changeCount
        pasteboardTimer?.invalidate()
        pasteboardTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkLocalPasteboardChanges()
            }
        }
    }

    /**
     * WHAT IT DOES: Stops the clipboard polling timer.
     * HOW IT DOES IT: Invalidates `pasteboardTimer` and sets it to nil.
     * WHY IT DOES IT: Prevents unnecessary CPU wakeups when the app is suspended.
     */
    public func stopClipboardMonitor() {
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
    }

    /**
     * WHAT IT DOES:
     *   Inspects the local clipboard, hashes copied text, and transmits it to Android.
     *
     * HOW IT DOES IT:
     *   1. Compares `NSPasteboard.general.changeCount` with `lastChangeCount`.
     *   2. Reads `string(forType: .string)`.
     *   3. Computes a SHA-256 hexadecimal digest via `CryptoKit.SHA256`.
     *   4. Guards that `shaHex != lastSyncedHash`.
     *   5. Updates `lastSyncedHash` and emits a `CLIPBOARD_EVENT` over the P2P client.
     *
     * WHY IT DOES IT:
     *   - `changeCount` fast-path check avoids expensive string reads when nothing changed.
     *   - SHA-256 deduplication is critical: when Android receives text and sets its
     *     clipboard, that event must not bounce back to macOS in an infinite ping-pong loop.
     */
    private func checkLocalPasteboardChanges() {
        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let copiedString = NSPasteboard.general.string(forType: .string),
              !copiedString.isEmpty else {
            return
        }

        let digest = SHA256.hash(data: Data(copiedString.utf8))
        let shaHex = digest.map { String(format: "%02x", $0) }.joined()

        guard shaHex != lastSyncedHash else { return }
        lastSyncedHash = shaHex

        p2pClient.sendControlJSON([
            "type": "CLIPBOARD_EVENT",
            "contentType": "PLAIN_TEXT",
            "textValue": copiedString,
            "contentSha256": shaHex
        ])
    }

    /**
     * WHAT IT DOES:
     *   Writes remote text received from Android into the local macOS clipboard.
     *
     * HOW IT DOES IT:
     *   - Checks that `sha256 != lastSyncedHash` to drop echo frames.
     *   - Records `lastSyncedHash = sha256`.
     *   - Clears `NSPasteboard.general` and writes the incoming string.
     *   - Immediately updates `lastChangeCount = pb.changeCount`.
     *
     * WHY IT DOES IT:
     *   Updating `lastChangeCount` immediately after writing ensures that our own
     *   local monitor timer does not mistake this remote write for a user copy action.
     */
    private func applyIncomingClipboard(text: String, sha256: String) {
        guard sha256 != lastSyncedHash else { return }
        lastSyncedHash = sha256

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
    }

    // =========================================================================
    // MARK: - 2. Native macOS UNUserNotificationCenter Bridge
    // =========================================================================

    /**
     * WHAT IT DOES:
     *   Registers notification categories and actions with macOS Notification Center.
     *
     * HOW IT DOES IT:
     *   - Checks `Bundle.main.bundleIdentifier != nil`. If nil (standalone binary mode),
     *     skips `UNUserNotificationCenter` to avoid `NSInternalInconsistencyException`.
     *   - Defines `UNTextInputNotificationAction` with identifier `"INLINE_REPLY_ACTION"`.
     *   - Defines destructive `UNNotificationAction` with identifier `"DISMISS_ACTION"`.
     *   - Creates `UNNotificationCategory` for `"ANDROID_MIRRORED_NOTIFICATION"`.
     *   - Requests user authorization for `.alert`, `.sound`, and `.badge`.
     *
     * WHY IT DOES IT:
     *   Allows macOS banners to present "Reply" text input fields and "Dismiss on Phone"
     *   buttons directly inside macOS system banner alerts.
     */
    private func configureNativeNotifications() {
        guard Bundle.main.bundleIdentifier != nil else {
            print("[LinkMyMac] Running in standalone CLI binary mode. Bundle ID is nil; native UNUserNotificationCenter banners disabled.")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let replyAction = UNTextInputNotificationAction(
            identifier: "INLINE_REPLY_ACTION",
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply to Android..."
        )

        let dismissAction = UNNotificationAction(
            identifier: "DISMISS_ACTION",
            title: "Dismiss on Phone",
            options: [.destructive]
        )

        let category = UNNotificationCategory(
            identifier: "ANDROID_MIRRORED_NOTIFICATION",
            actions: [replyAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /**
     * WHAT IT DOES:
     *   Posts an active desktop banner alert for an incoming Android notification.
     *
     * HOW IT DOES IT:
     *   - Constructs `UNMutableNotificationContent` with title (`appName — title`), body, and sound.
     *   - Attaches `userInfo` dictionary containing `notificationKey` and `defaultActionId`.
     *   - Creates a `UNNotificationRequest` and queues it via `UNUserNotificationCenter.current().add()`.
     *
     * WHY IT DOES IT:
     *   Ensures users see notifications in real-time in the macOS Notification Center
     *   even when LinkMyMac is hidden or behind other application windows.
     */
    private func postMacOSBannerNotification(_ item: MirroredNotification) {
        guard Bundle.main.bundleIdentifier != nil else {
            print("[LinkMyMac Notification] [\(item.appName)] \(item.title) — \(item.body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "\(item.appName) — \(item.title)"
        content.body = item.body
        content.sound = .default
        content.categoryIdentifier = "ANDROID_MIRRORED_NOTIFICATION"
        content.userInfo = [
            "notificationKey": item.id,
            "defaultActionId": item.actions.first?.id ?? "act_0"
        ]

        if let iconData = item.appIconData {
            let tmpDir = FileManager.default.temporaryDirectory
            let iconUrl = tmpDir.appendingPathComponent("notif_\(abs(item.id.hashValue))_icon.png")
            if (try? iconData.write(to: iconUrl)) != nil {
                if let attachment = try? UNNotificationAttachment(identifier: "appIcon", url: iconUrl, options: nil) {
                    content.attachments = [attachment]
                }
            }
        }

        let request = UNNotificationRequest(
            identifier: item.id,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /**
     * WHAT IT DOES:
     *   Handles user interaction with a macOS banner notification (clicking Reply or Dismiss).
     *
     * HOW IT DOES IT:
     *   - Extracts `notificationKey` and `actionId` from `response.notification.request.content.userInfo`.
     *   - If action is `"INLINE_REPLY_ACTION"`: casts response to `UNTextInputNotificationResponse`,
     *     extracts `userText`, and calls `p2pClient.sendNotificationReply()`.
     *   - If action is `"DISMISS_ACTION"`: calls `p2pClient.dismissNotification()`.
     *   - Invokes `completionHandler()` to signal macOS the event was processed.
     *
     * WHY IT DOES IT:
     *   Enables full bidirectional control: user replies typed on macOS are routed
     *   to Android's `RemoteInput` engine to reply to WhatsApp/SMS/Slack automatically.
     */
    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let notificationKey = userInfo["notificationKey"] as? String ?? ""
        let actionId = userInfo["defaultActionId"] as? String ?? "act_0"

        if response.actionIdentifier == "INLINE_REPLY_ACTION",
           let textResponse = response as? UNTextInputNotificationResponse {
            let replyText = textResponse.userText
            Task { @MainActor in
                self.p2pClient.sendNotificationReply(
                    notificationKey: notificationKey,
                    actionId: actionId,
                    replyText: replyText
                )
            }
        } else if response.actionIdentifier == "DISMISS_ACTION" {
            Task { @MainActor in
                self.p2pClient.dismissNotification(notificationKey: notificationKey)
            }
        }

        completionHandler()
    }
}
