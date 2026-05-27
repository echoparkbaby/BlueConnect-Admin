// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BlueConnectAdmin",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "BlueConnectAdmin",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/BlueConnect",
            // Tools 6.0 defaults to Swift 6 language mode, which turns
            // existing Sendable warnings into errors. Staying on Swift
            // 5 mode keeps the bar where it was — Swift 6 migration is
            // a separate, larger refactor.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Tiny SwiftUI CLI installed on target Macs as
        // /usr/local/bin/blueconnect-chat. Spawned by the GUI Helper
        // LaunchAgent inside the console user's Aqua session so it has
        // WindowServer access. Reads the admin's incoming messages from
        // a session directory, writes the user's outgoing replies back.
        // No deps — uses only AppKit / SwiftUI / Foundation so the
        // binary stays small and self-contained.
        .executableTarget(
            name: "BlueConnectChat",
            path: "Sources/BlueConnectChat",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Swift Testing target. Seed cases cover pure helpers
        // (URL composition, drag-payload round-trip, UniFi decoder)
        // — the surfaces where a regression would be silent. UI and
        // network paths are tested manually for now.
        .testTarget(
            name: "BlueConnectAdminTests",
            dependencies: ["BlueConnectAdmin"],
            path: "Tests/BlueConnectAdminTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
