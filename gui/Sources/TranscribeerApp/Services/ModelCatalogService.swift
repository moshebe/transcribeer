import Foundation
import WhisperKit

/// A Whisper model entry shown in the settings picker.
struct WhisperModelEntry: Hashable, Identifiable, Sendable {
    let id: String
    let isDownloaded: Bool
    let isRecommendedDefault: Bool
    let isDisabled: Bool

    var displayName: String { Self.friendlyName(for: id) }

    /// Turn a repo identifier like `openai_whisper-large-v3_turbo` into a
    /// human label like `large-v3 turbo`.
    static func friendlyName(for id: String) -> String {
        let stripped: String
        if id.hasPrefix("openai_whisper-") {
            stripped = String(id.dropFirst("openai_whisper-".count))
        } else if id.hasPrefix("distil-whisper_distil-") {
            stripped = "distil-" + id.dropFirst("distil-whisper_distil-".count)
        } else {
            stripped = id
        }
        return stripped.replacingOccurrences(of: "_", with: " ")
    }
}

/// Discovers available and already-downloaded WhisperKit models.
///
/// Uses the same download location that `TranscriptionService` configures on
/// `WhisperKitConfig.downloadBase`, so "downloaded" badges match what will
/// actually be reused at runtime.
@Observable @MainActor
final class ModelCatalogService {
    private(set) var entries: [WhisperModelEntry] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    private static let modelsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/models", isDirectory: true)
    }()

    /// HuggingFace snapshots land under `<downloadBase>/models/<repoId>/<variant>/`.
    private static let snapshotDir: URL = {
        modelsDir
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }()

    /// Refresh the catalog. Fetches remote support config (~a few KB) and
    /// lists the local snapshot directory. Safe to call on `.task` / `.refreshable`.
    func refresh() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let downloaded = Self.locallyDownloadedVariants()

        // `recommendedRemoteModels` swallows network errors internally and
        // falls back to `Constants.fallbackModelSupportConfig`, so this call
        // never throws. We still surface an empty remote list as an error so
        // users see *something* went wrong instead of silent fallback.
        let support = await WhisperKit.recommendedRemoteModels(downloadBase: Self.modelsDir)
        if support.supported.isEmpty {
            lastError = "Could not fetch the Whisper model list. Showing cached models."
        }

        // Preserve the remote ordering so newer/better models appear where
        // WhisperKit puts them, then append any on-disk extras (e.g. a model
        // that used to be supported and the user still has cached).
        var seen: Set<String> = []
        var list: [WhisperModelEntry] = []

        for id in support.supported {
            seen.insert(id)
            list.append(
                WhisperModelEntry(
                    id: id,
                    isDownloaded: downloaded.contains(id),
                    isRecommendedDefault: id == support.default,
                    isDisabled: false
                )
            )
        }
        for id in support.disabled where !seen.contains(id) {
            seen.insert(id)
            list.append(
                WhisperModelEntry(
                    id: id,
                    isDownloaded: downloaded.contains(id),
                    isRecommendedDefault: false,
                    isDisabled: true
                )
            )
        }
        for id in downloaded.sorted() where !seen.contains(id) {
            list.append(
                WhisperModelEntry(id: id, isDownloaded: true, isRecommendedDefault: false, isDisabled: false)
            )
        }

        entries = list
    }

    /// Ensure the currently-selected model is represented in `entries` even if
    /// the remote catalog omitted it (offline, custom repo, etc.).
    func ensureEntry(for id: String) {
        guard !id.isEmpty, !entries.contains(where: { $0.id == id }) else { return }
        let downloaded = Self.locallyDownloadedVariants().contains(id)
        entries.append(
            WhisperModelEntry(
                id: id,
                isDownloaded: downloaded,
                isRecommendedDefault: false,
                isDisabled: false
            )
        )
    }

    // MARK: - Local snapshot scan

    /// Scan `~/.transcribeer/models/models/argmaxinc/whisperkit-coreml/` for
    /// variant folders that look fully downloaded (have at least one mlmodelc
    /// or mlpackage inside).
    private static func locallyDownloadedVariants() -> Set<String> {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: snapshotDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: Set<String> = []
        for url in children where isDirectory(url) && looksLikeModelFolder(url) {
            result.insert(url.lastPathComponent)
        }
        return result
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private static func looksLikeModelFolder(_ url: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            return false
        }
        return entries.contains { $0.hasSuffix(".mlmodelc") || $0.hasSuffix(".mlpackage") }
    }
}
