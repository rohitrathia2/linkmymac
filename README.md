# LinkMyMac — Open-Source Cross-Device P2P Bridge (macOS ⇄ Android)

A complete, local-first peer-to-peer bridge connecting **macOS** (Swift 6 / SwiftUI / AppKit) and **Android** (Kotlin / Foreground Daemon / NotificationListenerService) over local Wi-Fi, Personal Hotspot, or USB ADB loopback with **zero cloud accounts**.

---

## Repository Structure

```
linkmymac-project/
├── protocol/
│   ├── linkmymac_protocol.proto     # Shared Protobuf schema for P2P wire frames
│   └── WIRE_SPEC.md                 # 8-byte length-delimited header & mTLS spec
├── android-app/                     # Android Companion & Foreground Daemon (Kotlin)
│   ├── build.gradle.kts
│   └── src/main/
│       ├── AndroidManifest.xml
│       └── java/com/linkmymac/android/
│           ├── crypto/CryptoKeystoreManager.kt    # AndroidKeyStore EC P-256 & QR builder
│           ├── service/P2PDaemonService.kt        # NsdManager mDNS & 8-byte framed socket
│           ├── service/LMMNotificationListener.kt # StatusBarNotification & RemoteInput reply
│           ├── service/ClipboardSyncHelper.kt     # Bidirectional clipboard with SHA-256 dedup
│           ├── service/MediaStoreProvider.kt      # 200x200 WebP thumbnails & 64KB chunking
│           └── ui/MainActivity.kt                 # Pairing dashboard & permission launcher
└── macos-app/                       # Native macOS Client & Menu Bar Extra (Swift 6)
    ├── Package.swift
    └── Sources/LinkMyMac/
        ├── LinkMyMacApp.swift       # SwiftUI SplitView Dashboard + MenuBarExtra
        ├── MacP2PClient.swift       # NWBrowser Bonjour discovery & NWConnection framing
        └── MacSubsystems.swift      # NSPasteboard observer & UNUserNotificationCenter bridge
```

---

## Quick Start & Build Instructions

### 1. Build & Run the Android Companion App
1. Open `android-app/` in **Android Studio (Ladybug or newer)**.
2. Connect your Android phone and run the `app` configuration (minSdk 29 / Android 10+).
3. On the phone screen:
   - Tap **"1. Grant Notification Mirroring Access"** and enable **LinkMyMac Notification Bridge** in Android Settings.
   - Note the displayed local IP address and port (`8765`), or connect via USB and run:
     ```bash
     adb forward tcp:8765 tcp:8765
     ```

### 2. Build & Run the macOS Client
1. Open a terminal on your Mac (macOS 14.0 Sonoma or newer):
   ```bash
   cd macos-app
   swift build
   swift run LinkMyMac
   ```
2. Or open `macos-app/Package.swift` directly in **Xcode 16+**.
3. The app automatically discovers `_linkmymac._tcp` peers via Bonjour, or you can click **"Connect USB (adb forward)"** / enter your phone's LAN IP.

---

## Apple Continuity Feature Mapping & Architecture

| Apple Ecosystem Feature | What It Does on iPhone ⇄ Mac | Android API / Subsystem | macOS API / Subsystem | Implementation Complexity & Notes |
|:---|:---|:---|:---|:---|
| **iPhone Notifications & Quick Reply** | Mirrors phone alerts to Mac Notification Center with inline replies (Apple Continuity) | `NotificationListenerService` + `RemoteInput` | `UNUserNotificationCenter` | Low (Implemented) |
| **Universal Clipboard** | Copy text, links, or images on one device and paste on the other (Apple Continuity) | `ClipboardManager` (`OnPrimaryClipChangedListener`) | `NSPasteboard` (`changeCount` observer) | Low–Medium (Implemented for text & history) |
| **AirDrop & iCloud Photo Sync** | High-speed local file drops and instant camera roll browsing (Apple Continuity) | `MediaStore` + 64 KB chunked stream | `NWConnection` + `NSDraggingDestination` + `NSSharingServicePicker` | Low–Medium (Implemented with Sync All, Share & Delete) |
| **Text Message Forwarding** | Read and send SMS/MMS conversations directly from Mac (Apple Continuity) | `SmsManager` + `Telephony.Sms` provider | SwiftUI Chat View + Network frame | Low (Requires `SEND_SMS` and `READ_SMS` permissions; sideloaded or companion permission grant) |
| **iPhone Mirroring** | View and interact with the phone screen wirelessly from a Mac window (Apple Continuity) | `MediaProjectionManager` (MediaProjection H.264/HEVC) + `AccessibilityService` (`dispatchGesture`) | `VideoToolbox` hardware decoder + `MTKView` / `AVSampleBufferDisplayLayer` | High (Video uses MediaProjection; remote touch/scroll injection uses AccessibilityService or adb shell input) |
| **Continuity Camera (FaceTime / Webcam)** | Use the phone's camera and mic as a high-res Mac webcam with 1-click lens flip (Apple Continuity) | `CameraManager` (`android.hardware.camera2`) | Core Media I/O (`CMIOExtensionProviderSource`) + SwiftUI Viewport | High for system virtual camera / Medium for in-app FaceTime viewer (Implemented in-app with Front/Back switch & orientation tracking) |
| **iPhone Cellular Calls** | Answer, place, and route phone calls using the Mac's mic and speakers (Apple Continuity) | `TelecomManager` + `TelephonyManager` | Bluetooth HFP Hands-Free Role + Call Alert UI | Medium–High (Call metadata/accept/reject routes over LAN; voice audio routes via standard Bluetooth Hands-Free Profile) |
| **Universal Control (Mouse & Keyboard)** | Move the Mac cursor and keyboard seamlessly onto the phone screen (Apple Continuity) | `BluetoothHidDevice` or `AccessibilityService` | `CGEventTap` (captures cursor edge exit & keystrokes) | Medium (Mac captures edge mouse movement and acts as a Bluetooth HID combo mouse/keyboard or sends coordinates over LAN) |
| **Instant Hotspot** | Enable the phone's Wi-Fi hotspot from the Mac menu bar without touching the phone (Apple Continuity) | `CompanionDeviceManager` + BLE Trigger + Tethering | `CoreBluetooth` BLE Central + `CoreWLAN` | Medium (Uses BLE advertisement so the Mac can see battery/signal and request hotspot activation even when offline) |
| **Handoff & Now Playing Control** | Pass active web tabs/tasks between devices and control phone media playback on Mac (Apple Continuity) | `android.media` (`MediaController` via `NotificationListenerService`) + Share Target | `NSWorkspace.shared.open(url)` + Media Control Bar | Low (Sharing any URL to "Send to Mac" opens the active browser tab immediately on macOS) |
| **Continuity Sketch & Document Scanner** | Scan physical documents with the phone camera or sketch on the phone and insert live on Mac (Apple Continuity) | `CameraManager` + Compose Canvas | `NSPasteboard` / Finder Quick Action | Low–Medium (Captures perspective-corrected PDF/PNG on Android and streams directly into the active Mac pasteboard or cursor) |
