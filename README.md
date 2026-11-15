# LinkMyMac — Android ⇄ macOS bridge, no cloud

Mirrors notifications, syncs the clipboard, browses and downloads the phone's photos and videos, shows the phone camera on the Mac, and shares files both ways. Everything goes directly between the two devices over Wi-Fi or a USB cable. No accounts, no cloud.

- **Android companion** (`android-app/`, Kotlin): a foreground service that listens on TCP 8765 and advertises `_linkmymac._tcp` over Bonjour/mDNS.
- **macOS app** (`macos-app/`, Swift 6 / SwiftUI, shown as "UniBridge"): finds the phone over Bonjour or connects through USB (`adb forward`).
- **Protocol** (`protocol/WIRE_SPEC.md`): length-framed JSON over TCP, plus pairing and authentication.

---

## Repository layout

```
linkmymac-project/
├── protocol/
│   ├── WIRE_SPEC.md                  # framing, pairing/auth, file transfer, message list
│   ├── e2e_check.py                  # on-device protocol check over USB (see Testing)
│   └── linkmymac_protocol.proto      # planned binary schema, not used on the wire yet
├── android-app/src/main/java/com/linkmymac/android/
│   ├── crypto/PairingManager.kt      # pairing code, ECDH pairing, HMAC challenge
│   ├── crypto/CryptoKeystoreManager.kt  # QR pairing payload
│   ├── service/P2PDaemonService.kt   # TCP server, auth gate, file streaming
│   ├── service/LMMNotificationListener.kt  # notification mirroring + quick reply
│   ├── service/ClipboardSyncHelper.kt      # clipboard sync with SHA-256 dedup
│   ├── service/MediaStoreProvider.kt # photo + video gallery, thumbnails, delete
│   ├── service/CameraStreamProvider.kt     # phone camera frames
│   └── ui/MainActivity.kt            # dashboard, pairing code, share target
└── macos-app/
    ├── bundle.sh                     # builds ../LinkMyMac.app (release, ad-hoc signed)
    ├── Info.plist
    └── Sources/LinkMyMac/
        ├── LinkMyMacApp.swift        # dashboard window + menu bar
        ├── MacP2PClient.swift        # discovery, connection, auth, file transfer
        ├── MacSubsystems.swift       # clipboard watcher, notification banners
        └── MacMediaManager.swift     # Mac "Now Playing" bridge
```

## Build and run

**Android** (Android 10+):
```bash
cd android-app
./gradlew assembleDebug
adb install -r build/outputs/apk/debug/LinkMyMac-Android-debug.apk
```
Open the app and grant notification access and all-files access when it asks.

**macOS** (14 Sonoma+):
```bash
macos-app/bundle.sh        # builds LinkMyMac.app next to this README
open LinkMyMac.app
```
`cd macos-app && swift run` also works for development, but notification banners need the `.app` bundle.

**Connect**
- USB: `adb forward tcp:8765 tcp:8765`. On launch the Mac app connects to the last host it used, which is 127.0.0.1:8765 (USB) by default.
- Wi-Fi: put both devices on the same network. The Mac finds the phone over Bonjour, or you can enter the phone's IP under QR Code Pairing → Manual IP.

**Pair (once per Mac)**
The first time a Mac connects, the phone shows a 6-character code in its top status badge and in the "Pair with your Mac" card. Type it into the prompt in the Mac sidebar, or scan the phone's QR code from the Mac's QR Code Pairing tab. After that, the devices reconnect on their own. "Forget Paired Macs" on the phone revokes every Mac.

## Features

| Feature | Status | How |
|:---|:---|:---|
| Notification mirroring + quick reply | ✅ | `NotificationListenerService` + `RemoteInput` → `UNUserNotificationCenter` |
| Clipboard sync (text) | ✅ | `ClipboardManager` ⇄ `NSPasteboard`, SHA-256 dedup |
| Photos & videos: browse, download, share, delete | ✅ | MediaStore images + videos → Photos & Videos tab; videos play in AVKit after download |
| File sharing, both directions | ✅ | Mac: File Sharing tab (drop zone), Dock icon, menu bar. Android: Share → LinkMyMac Companion, or "Send Files to Mac" |
| Phone camera on the Mac | ✅ in-app only | camera2 JPEG frames shown in the app; it is not a system webcam (no CMIO extension) |
| Mac "Now Playing" controls on the phone | ✅ | Media notification on Android |
| Shared links/text from Android | ⚠️ partial | They land on the Mac clipboard; nothing opens automatically |
| SMS from the Mac | ❌ not built | |
| Screen mirroring | ❌ not built | |
| Phone calls through the Mac | ❌ not built | |
| Mouse/keyboard sharing | ❌ not built | |
| Instant hotspot | ❌ not built | |
| Continuity Sketch / document scanner | ❌ not built | |

## Security model

- The phone ignores every frame from a connection until it proves it's a paired Mac. The proof is an HMAC challenge-response on a fresh nonce, so a captured answer can't be replayed. The shared secret comes from a one-time P-256 ECDH exchange authorised by the on-screen code, so it never travels over the network.
- The Mac checks the phone the same way, so a fake device advertising `_linkmymac._tcp` can't push clipboard text, notifications or files into the Mac.
- Pairing codes are single-use, and a wrong code blocks code attempts for 3 seconds.
- **Not done yet: transport encryption.** On Wi-Fi, someone on the same network can read notifications, clipboard text and files in transit. An active attacker (ARP spoofing, or a fake Bonjour service relaying traffic) could take over an authenticated session. USB traffic (`adb forward`) never touches the network. The fix is TLS with the phone's certificate pinned at pairing; the QR code already carries its fingerprint.

## Android permissions

- Notification access and foreground service: the bridge itself.
- All-files access (`MANAGE_EXTERNAL_STORAGE`): needed only so "Delete from Mac" can remove photos and videos made by other apps. Google Play restricts this permission. A Play build should switch to `MediaStore.createDeleteRequest`, which asks on the phone.
- Camera: the phone-camera view.
- App names and icons for mirrored notifications use a `<queries>` filter for launcher apps instead of `QUERY_ALL_PACKAGES`.
- No SMS, contacts or call permissions.

## Testing

With the phone on USB:
```bash
adb forward tcp:8765 tcp:8765
python3 protocol/e2e_check.py --code <code shown on the phone>
```
It plays the Mac's role against the real phone and checks:
- the pairing gate: unpaired clients get nothing, wrong codes are rejected, retries are rate-limited, replayed proofs fail
- photo and video streaming
- a Mac → phone file transfer

It leaves a test "Mac" paired on the phone; use "Forget Paired Macs" to remove it.
