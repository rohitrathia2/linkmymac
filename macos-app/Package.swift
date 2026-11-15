// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LinkMyMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LinkMyMac", targets: ["LinkMyMac"])
    ],
    targets: [
        .executableTarget(
            name: "LinkMyMac",
            path: "Sources/LinkMyMac",
            resources: [
                .copy("Resources")
            ],
            // SwiftUI's VideoPlayer subclasses AVKit's AVPlayerView, which the Swift runtime looks up
            // by name. No code here uses an AVKit symbol directly, so the linker drops the auto-linked
            // AVKit and playback aborts: "failed to demangle superclass of VideoPlayerView".
            linkerSettings: [.linkedFramework("AVKit")]
        )
    ]
)
