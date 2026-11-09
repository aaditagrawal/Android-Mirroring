// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AndroidMirroring",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AndroidMirroring", targets: ["AndroidMirroring"]),
        .executable(name: "droidctl", targets: ["droidctl"]),
        .library(name: "MirrorKit", targets: ["MirrorKit"]),
    ],
    targets: [
        // Wire types shared by the app's agent server and the droidctl CLI / MCP bridge.
        .target(
            name: "AgentProtocol",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // ADB client, scrcpy session, decoding, connection management, agent server.
        .target(
            name: "MirrorKit",
            dependencies: ["AgentProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-Ounchecked"], .when(configuration: .release))],
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Network"),
            ]
        ),
        .executableTarget(
            name: "AndroidMirroring",
            dependencies: ["MirrorKit", "AgentProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "droidctl",
            dependencies: ["AgentProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "mirror-bench",
            dependencies: ["MirrorKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "mirror-selftest",
            dependencies: ["MirrorKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MirrorKitTests",
            dependencies: ["MirrorKit", "AgentProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
