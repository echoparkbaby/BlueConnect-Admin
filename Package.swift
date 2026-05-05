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
    ]
)
