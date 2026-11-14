// swift-tools-version:5.9
// Vendored SwiftTerm library target only (no termcast/fuzz/benchmark targets
// or their dependencies). Provenance and update steps: README.md.
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v14), .macOS(.v13), .tvOS(.v13), .visionOS(.v1)],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: ["Mac/README.md"],
            resources: [.process("Apple/Metal/Shaders.metal")]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
