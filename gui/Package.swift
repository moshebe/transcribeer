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
    ],
    targets: [
        .executableTarget(
            name: "TranscribeerApp",
            dependencies: [
                "TOMLDecoder",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "SpeakerKit", package: "WhisperKit"),
                .product(name: "LLM", package: "LLM"),
                .product(name: "HighlightedTextEditor", package: "HighlightedTextEditor"),
            ],
            path: "Sources/TranscribeerApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TranscribeerTests",
            dependencies: ["TranscribeerApp"],
            path: "Tests/TranscribeerTests"
        ),
    ]
)
