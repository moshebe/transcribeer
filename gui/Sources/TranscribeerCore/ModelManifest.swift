import Foundation

/// Metadata for a Transcribeer-hosted Whisper model published as a GitHub Release asset.
public struct ModelManifestEntry: Sendable {
    public let id: String
    public let displayName: String
    public let sizeBytes: Int64
    /// SHA-256 hex digest of the `.tar.zst` tarball.
    public let sha256: String
    public let downloadURL: URL
    /// The folder name produced by whisperkit-generate-model, used as the final directory
    /// under the WhisperKit cache path so TranscriptionService.cachedModelFolder picks it up.
    public let extractedFolderName: String

    public init(
        id: String,
        displayName: String,
        sizeBytes: Int64,
        sha256: String,
        downloadURL: URL,
        extractedFolderName: String
    ) {
        self.id = id
        self.displayName = displayName
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.downloadURL = downloadURL
        self.extractedFolderName = extractedFolderName
    }
}

// MARK: - HuggingFace base URL

private let hfRepoBase = "https://huggingface.co/datasets/moshebehf/transcribeer-coreml-models/resolve/main"

private func hfModelURL(_ filename: String) -> URL {
    guard let url = URL(string: "\(hfRepoBase)/\(filename)") else {
        // Compile-time constants — this path is unreachable in practice.
        preconditionFailure("Invalid HuggingFace model URL for \(filename)")
    }
    return url
}

// MARK: - Manifest

/// Compile-time manifest of ivrit.ai CoreML models hosted on HuggingFace.
///
/// URLs and SHA-256 digests are pinned at build time. Updates ship with new app versions.
public enum ModelManifest {
    public static let hebrewTurbo = ModelManifestEntry(
        id: "ivrit-ai_whisper-large-v3-turbo",
        displayName: "Hebrew — turbo (ivrit.ai)",
        sizeBytes: 1_490_000_000,
        sha256: "b75a55d1ab5fe2db4ad2e46fc5166ab9c5fe67fe090a4fcde585bb3c0bbcb9fa",
        downloadURL: hfModelURL("ivrit-ai_whisper-large-v3-turbo.tar.zst"),
        extractedFolderName: "ivrit-ai_whisper-large-v3-turbo"
    )

    public static let hebrewLarge = ModelManifestEntry(
        id: "ivrit-ai_whisper-large-v3",
        displayName: "Hebrew — large (ivrit.ai, most accurate)",
        sizeBytes: 2_840_000_000,
        sha256: "f263c439e700b5aee34c34d36de678e86315673cdfa5fa4b3c9e8e9dcf488c5e",
        downloadURL: hfModelURL("ivrit-ai_whisper-large-v3.tar.zst"),
        extractedFolderName: "ivrit-ai_whisper-large-v3"
    )

    public static let all: [ModelManifestEntry] = [hebrewTurbo, hebrewLarge]
}
