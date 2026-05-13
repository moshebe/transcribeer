// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "capture",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CaptureCore", targets: ["CaptureCore"]),
    ],
    targets: [
        .target(
            name: "CaptureCore",
            path: "Sources/CaptureCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .testTarget(
            name: "captureCoreTests",
            dependencies: ["CaptureCore"],
            path: "Tests/captureCoreTests"
        ),
    ]
)
