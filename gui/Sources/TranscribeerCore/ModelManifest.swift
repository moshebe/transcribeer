import Foundation

/// Metadata for a Transcribeer-hosted Whisper model published as a GitHub Release asset.
public struct ModelManifestEntry: Sendable {
    public let id: String
    public let displayName: String
    public let sizeBytes: Int64
    /// SHA-256 hex digest of the `.tar.zst` tarball.
    /// TODO(models-v1): replace `__PENDING__` after running scripts/publish-ivrit-coreml.sh
    /// and uploading to the GitHub Release.
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

// MARK: - Release base URL

private let modelsReleaseBase = "https://github.com/moshebe/transcribeer/releases/download/models-v1"

private func modelReleaseURL(_ filename: String) -> URL {
    guard let url = URL(string: "\(modelsReleaseBase)/\(filename)") else {
        // Compile-time constants — this path is unreachable in practice.
        preconditionFailure("Invalid model release URL for \(filename)")
    }
    return url
}

// MARK: - Manifest

/// Compile-time manifest of ivrit.ai CoreML models hosted on GitHub Releases.
///
/// URLs and SHA-256 digests are pinned at build time — the app never hits the
/// GitHub API at runtime. Updates ship with new app versions.
///
/// TODO(models-v1): fill `sha256` fields after running `scripts/publish-ivrit-coreml.sh`
/// and uploading both tarballs to the `models-v1` GitHub Release.
public enum ModelManifest {
    public static let hebrewTurbo = ModelManifestEntry(
        id: "ivrit-ai_whisper-large-v3-turbo",
        displayName: "Hebrew — turbo (ivrit.ai)",
        sizeBytes: 1_600_000_000,
        sha256: "__PENDING__",
        downloadURL: modelReleaseURL("ivrit-ai_whisper-large-v3-turbo.tar.zst"),
        extractedFolderName: "ivrit-ai_whisper-large-v3-turbo"
    )

    public static let hebrewLarge = ModelManifestEntry(
        id: "ivrit-ai_whisper-large-v3",
        displayName: "Hebrew — large (ivrit.ai, most accurate)",
        sizeBytes: 3_000_000_000,
        sha256: "__PENDING__",
        downloadURL: modelReleaseURL("ivrit-ai_whisper-large-v3.tar.zst"),
        extractedFolderName: "ivrit-ai_whisper-large-v3"
    )

    public static let all: [ModelManifestEntry] = [hebrewTurbo, hebrewLarge]
}
