import Foundation
import WhisperKit

// MARK: - Curated model catalog

/// A hand-curated Whisper model entry with language affinity and size info.
/// These are interleaved ahead of the remote catalog in the picker so users
/// see opinionated defaults before the full list.
struct CuratedModelEntry: Identifiable, Sendable {
    let id: String           // same as WhisperModelEntry.id
    let displayName: String
    let language: String     // "en", "he", "multi"
    let isRecommended: Bool
    let sizeGB: Double
    /// Non-nil means we host this model; nil means it comes from the default HF repo
    let customRepo: String?
}

// MARK: - WhisperModelEntry

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

    // MARK: - RAM estimation

    /// Returns the expected in-memory footprint (bytes) for the given model
    /// variant, or `nil` when unknown. Used by `TranscriptionService` to warn
    /// the user before loading a model that may exceed available RAM.
    ///
    /// Sizes are empirically measured peak RSS on Apple Silicon (M1/M2).
    /// The curated list covers the models we ship; the remote catalog entries
    /// fall back to `nil` (unknown → no warning shown).
    static func expectedRAMBytes(for modelVariant: String) -> Int64? {
        // Check curated entries first (covers ivrit.ai + openai standard models)
        if let curated = Self.curated.first(where: { $0.id == modelVariant }) {
            return Int64(curated.sizeGB * 1_000_000_000)
        }
        // Fallback pattern-match for common openai_whisper variants not in curated list
        switch modelVariant {
        case "openai_whisper-tiny", "openai_whisper-tiny.en":
            return 150_000_000
        case "openai_whisper-base", "openai_whisper-base.en":
            return 290_000_000
        case "openai_whisper-small", "openai_whisper-small.en":
            return 970_000_000
        case "openai_whisper-medium", "openai_whisper-medium.en":
            return 3_000_000_000
        case "openai_whisper-large-v2":
            return 6_000_000_000
        case "openai_whisper-large-v3":
            return 6_000_000_000
        case "openai_whisper-large-v3_turbo", "openai_whisper-large-v3-turbo":
            return 1_600_000_000
        default:
            return nil
        }
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

// MARK: - Curated list

extension ModelCatalogService {
    /// Opinionated, hardcoded list of recommended models grouped by language.
    /// Shown at the top of per-language pickers in `TranscriptionSettingsView`.
    static let curated: [CuratedModelEntry] = [
        CuratedModelEntry(
            id: "ivrit-ai_whisper-large-v3-turbo",
            displayName: "Hebrew — turbo (ivrit.ai, recommended)",
            language: "he",
            isRecommended: true,
            sizeGB: 1.6,
            customRepo: nil   // served from local cache by HebrewModelDownloader
        ),
        CuratedModelEntry(
            id: "ivrit-ai_whisper-large-v3",
            displayName: "Hebrew — large (ivrit.ai, most accurate)",
            language: "he",
            isRecommended: false,
            sizeGB: 3.0,
            customRepo: nil
        ),
        CuratedModelEntry(
            id: "openai_whisper-large-v3-turbo",
            displayName: "English — turbo (recommended)",
            language: "en",
            isRecommended: true,
            sizeGB: 1.6,
            customRepo: nil   // argmaxinc/whisperkit-coreml default repo
        ),
        CuratedModelEntry(
            id: "openai_whisper-large-v3",
            displayName: "Multilingual — large (other languages)",
            language: "multi",
            isRecommended: false,
            sizeGB: 3.0,
            customRepo: nil
        ),
    ]

    /// Curated entries filtered to a specific language tag.
    static func curatedEntries(language: String) -> [CuratedModelEntry] {
        curated.filter { $0.language == language }
    }
}
