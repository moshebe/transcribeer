// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TranscribeeMenuBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TranscribeeMenuBar",
            path: "Sources/TranscribeeMenuBar"
        )
    ]
)
