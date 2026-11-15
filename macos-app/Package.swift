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
            ]
        )
    ]
)
