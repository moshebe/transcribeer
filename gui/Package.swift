// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TranscribeerApp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder.git", from: "0.2.2"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0"),
        .package(url: "https://github.com/bensyverson/LLM.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // Shared business logic — no GUI coupling
        .target(
            name: "TranscribeerCore",
            dependencies: [
                "TOMLDecoder",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
                .product(name: "LLM", package: "LLM"),
            ],
            path: "Sources/TranscribeerCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Native menubar GUI
        .executableTarget(
            name: "TranscribeerApp",
            dependencies: [
                "TranscribeerCore",
            ],
            path: "Sources/TranscribeerApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // CLI — record / transcribe / summarize / run
        .executableTarget(
            name: "transcribeer",
            dependencies: [
                "TranscribeerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/TranscribeerCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
