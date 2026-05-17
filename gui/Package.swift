// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TranscribeerApp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/dduan/TOMLDecoder.git", from: "0.2.2"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0"),
        .package(url: "https://github.com/bensyverson/LLM.git", branch: "main"),

        .package(url: "https://github.com/kyle-n/HighlightedTextEditor.git", from: "2.1.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui.git", from: "2.4.1"),
        .package(path: "../capture"),
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
                .product(name: "CaptureCore", package: "capture"),
                .product(name: "HighlightedTextEditor", package: "HighlightedTextEditor"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/TranscribeerApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .testTarget(
            name: "TranscribeerCoreTests",
            dependencies: ["TranscribeerCore"],
            path: "Tests/TranscribeerCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TranscribeerTests",
            dependencies: ["TranscribeerApp"],
            path: "Tests/TranscribeerTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
