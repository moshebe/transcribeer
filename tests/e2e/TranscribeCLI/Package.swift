// swift-tools-version: 6.0
import PackageDescription

// Tiny CLI used by the e2e harness to transcribe a WAV with the same
// WhisperKit model Transcribeer uses by default. Keeping it in a separate
// package avoids a test-only dependency on the GUI target.
let package = Package(
    name: "TranscribeCLI",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.18.0"),
    ],
    targets: [
        .executableTarget(
            name: "transcribe-cli",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/transcribe-cli",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
