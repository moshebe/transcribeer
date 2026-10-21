import Foundation

/// Locates WhisperKit model folders already on disk, using the layout `HubApi`
/// produces under `downloadBase` (`models/<owner>/<repo>/<variant>`).
public enum WhisperModelCache {
    public static let defaultRepo = "argmaxinc/whisperkit-coreml"

    /// Minimum viable set of CoreML bundles WhisperKit needs to load.
    private static let requiredBundles = [
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
    ]

    public static func folder(variant: String, repo: String?, downloadBase: URL) -> URL? {
        let parts = (repo ?? defaultRepo).split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }

        let folder = downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(String(parts[0]), isDirectory: true)
            .appendingPathComponent(String(parts[1]), isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)

        let fileManager = FileManager.default
        let allPresent = requiredBundles.allSatisfy { name in
            fileManager.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
        return allPresent ? folder : nil
    }
}
