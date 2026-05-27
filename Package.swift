// swift-tools-version: 5.9
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
            path: "Sources/BlueConnect"
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
            path: "Sources/BlueConnectChat"
        ),
    ]
)
