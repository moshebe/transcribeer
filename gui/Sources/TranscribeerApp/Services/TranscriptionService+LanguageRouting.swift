import Foundation
import os.log
import TranscribeerCore

private let logger = Logger(subsystem: "com.transcribeer", category: "language-routing")

// MARK: - Language routing

@MainActor
extension TranscriptionService {
    /// Languages with their own model setting in `effectiveModel(for:)`.
    static let routedLanguages: Set<String> = ["he", "en"]

    /// Compute the effective (model name, repo) pair for the given config.
    ///
    /// Language-specific routing takes priority over the general `whisperModel`
    /// setting so that a Hebrew recording always uses the ivrit.ai CoreML model
    /// regardless of what the generic picker shows.
    ///
    /// - `"he"` → `config.hebrewWhisperModel` / `config.hebrewWhisperModelRepo`
    /// - `"en"` → `config.englishWhisperModel` / `config.englishWhisperModelRepo`
    /// - anything else (including `"auto"`) → `config.whisperModel` / `config.whisperModelRepo`
    ///
    /// An empty repo string resolves to `nil` (use the default HF repo or local cache).
    func effectiveModel(for config: AppConfig) -> (name: String, repo: String?) {
        switch config.language {
        case "he":
            let repo = config.hebrewWhisperModelRepo.isEmpty ? nil : config.hebrewWhisperModelRepo
            return (config.hebrewWhisperModel, repo)
        case "en":
            let repo = config.englishWhisperModelRepo.isEmpty ? nil : config.englishWhisperModelRepo
            return (config.englishWhisperModel, repo)
        default:
            // "auto" or any unlisted language: use the general model setting
            let repo = config.whisperModelRepo.isEmpty ? nil : config.whisperModelRepo
            return (config.whisperModel, repo)
        }
    }

    /// In `auto` mode, detect the session's language with the general model and
    /// pin the config to it when that language has its own model. Otherwise the
    /// config is returned unchanged and WhisperKit detects per chunk as before.
    func routeAutoLanguage(session: URL, config: AppConfig) async -> AppConfig {
        guard config.language == "auto" else { return config }

        let sources = SourceAudioFiles.Source.allCases.compactMap { source in
            SourceAudioFiles.preferredURL(in: session, source: source)
        }
        let audioURLs = sources.isEmpty ? [session.appendingPathComponent("audio.m4a")] : sources

        do {
            try await loadModel(name: config.whisperModel, repo: config.whisperModelRepo)
        } catch {
            logger.error("detection model load failed: \(error.localizedDescription, privacy: .public)")
            return config
        }
        guard let kit = whisperKit else { return config }

        let detected = await LanguageDetector.detect(audioURLs: audioURLs, kit: kit)
        // The transcriber loads its own instances; don't hold a second copy in memory.
        await unloadModel()

        guard let detected, Self.routedLanguages.contains(detected) else { return config }
        logger.info("auto language routed to \(detected, privacy: .public)")
        var routed = config
        routed.language = detected
        return routed
    }
}
