import AVFoundation
import CoreMedia
import Foundation
import os
import Speech
import TranscribeerCore

/// Apple SpeechAnalyzer (macOS 26+) backend.
///
/// Runs the modern on-device Speech framework — `SpeechAnalyzer` + `SpeechTranscriber`
/// modules — over the same per-source (mic + sys) audio the WhisperKit path uses,
/// then merges results with `DualSourceTranscriber.mergeAndTag` so downstream
/// formatting, session output, and speaker labels stay identical.
///
/// SpeechAnalyzer is a strict superset of the legacy `SFSpeechRecognizer` for the
/// locales it supports (English variants, French, German, Italian, Spanish,
/// Portuguese-BR, Japanese, Korean, Mandarin, Cantonese, and a few others).
/// **Hebrew is not currently supported**, so we throw a clear error asking the
/// user to switch to WhisperKit for Hebrew recordings.
///
/// Availability: macOS 26.0+. All call sites gate with `#available(macOS 26.0, *)`.
@available(macOS 26.0, *)
enum SpeechAnalyzerTranscriber {
    private static let logger = Logger(
        subsystem: "com.transcribeer",
        category: "SpeechAnalyzerTranscriber",
    )

    /// Transcribe a session directory using SpeechAnalyzer.
    ///
    /// Mirrors `DualSourceTranscriber.transcribe(session:cfg:...)` so the caller
    /// (TranscriptionService) can swap engines without changing anything downstream.
    static func transcribe(
        session: URL,
        config: AppConfig,
        timing: DualSourceTranscriber.TimingInfo,
        onMicProgress: (@Sendable (Double) -> Void)? = nil,
        onSysProgress: (@Sendable (Double) -> Void)? = nil,
    ) async throws -> DualSourceTranscriber.TranscriptionOutput {
        let locale = try await resolveLocale(config.language)
        logger.info("using locale \(locale.identifier, privacy: .public)")
        try await ensureModelInstalled(locale: locale)

        let micURL = SourceAudioFiles.preferredURL(in: session, source: .mic)
        let sysURL = SourceAudioFiles.preferredURL(in: session, source: .sys)

        if micURL != nil || sysURL != nil {
            async let micSegs = optionallyTranscribe(micURL, locale: locale, onProgress: onMicProgress)
            async let sysSegs = optionallyTranscribe(sysURL, locale: locale, onProgress: onSysProgress)
            let mic = try await micSegs
            let sys = try await sysSegs

            if (mic?.isEmpty ?? true) && (sys?.isEmpty ?? true) {
                throw AudioValidationError.silent(
                    url: micURL ?? sysURL ?? session,
                    probeSeconds: 0,
                )
            }

            let merged = DualSourceTranscriber.mergeAndTag(
                micSegments: mic,
                sysSegments: sys,
                timing: timing,
                selfLabel: config.audio.selfLabel,
                otherLabel: config.audio.otherLabel,
            )
            return .init(
                segments: merged,
                detectedLanguage: locale.language.languageCode?.identifier,
            )
        }

        // Legacy mixed fallback
        let mixedURL = session.appendingPathComponent("audio.m4a")
        let segments = try await transcribeFile(url: mixedURL, locale: locale, onProgress: onMicProgress)
        let labeled = segments.map { seg in
            TranscribeerCore.LabeledSegment(
                start: seg.start,
                end: seg.end,
                speaker: config.audio.selfLabel,
                text: seg.text,
            )
        }
        return .init(
            segments: labeled,
            detectedLanguage: locale.language.languageCode?.identifier,
        )
    }

    // MARK: - Locale resolution

    /// Map the app's language config (`"auto"` / `"en"` / `"he"` / arbitrary)
    /// to a Locale actually supported by SpeechTranscriber. Throws when the
    /// requested locale has no equivalent.
    private static func resolveLocale(_ raw: String) async throws -> Locale {
        let candidate: Locale = switch raw {
        case "he", "he-IL": Locale(identifier: "he-IL")
        case "en", "en-US": Locale(identifier: "en-US")
        case "auto", "": Locale.current
        default: Locale(identifier: raw)
        }

        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) {
            return match
        }
        throw SpeechAnalyzerError.unsupportedLocale(candidate.identifier)
    }

    /// Ensure the on-device model for `locale` is installed. First launch on a
    /// new locale triggers a background download (~50–200 MB).
    private static func ensureModelInstalled(locale: Locale) async throws {
        let probe = SpeechTranscriber(locale: locale, preset: .transcription)
        let status = await AssetInventory.status(forModules: [probe])
        switch status {
        case .installed:
            return
        case .unsupported:
            throw SpeechAnalyzerError.unsupportedLocale(locale.identifier)
        case .supported, .downloading:
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: [probe],
            ) else {
                throw SpeechAnalyzerError.assetsUnavailable
            }
            logger.info("installing speech asset for \(locale.identifier, privacy: .public)")
            try await request.downloadAndInstall()
        }
    }

    // MARK: - Per-source transcription

    private static func optionallyTranscribe(
        _ url: URL?,
        locale: Locale,
        onProgress: (@Sendable (Double) -> Void)?,
    ) async throws -> [TranscribeerCore.TranscriptSegment]? {
        guard let url else { return nil }
        try Task.checkCancellation()
        do {
            try AudioValidation.ensureAudibleSignal(at: url)
        } catch {
            logger.info(
                "source \(url.lastPathComponent, privacy: .public) silent, skipping: \(error.localizedDescription, privacy: .public)",
            )
            return nil
        }
        return try await transcribeFile(url: url, locale: locale, onProgress: onProgress)
    }

    /// Transcribe a single audio file to timestamped segments.
    ///
    /// Feeds an `AVAudioFile` into `SpeechAnalyzer` with a `SpeechTranscriber`
    /// module and drains the results async sequence. Progress is estimated from
    /// each result's `range.end` divided by the file's total duration.
    private static func transcribeFile(
        url: URL,
        locale: Locale,
        onProgress: (@Sendable (Double) -> Void)?,
    ) async throws -> [TranscribeerCore.TranscriptSegment] {
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange],
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: url)
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        onProgress?(0)

        // The results sequence must be drained concurrently with `start(...)`,
        // otherwise the analyzer's internal buffer stalls and the file input
        // never completes. Kick off collection first, then start the analyzer,
        // then await both.
        let collectionTask = Task { () -> [TranscribeerCore.TranscriptSegment] in
            var segments: [TranscribeerCore.TranscriptSegment] = []
            for try await result in transcriber.results {
                let start = CMTimeGetSeconds(result.range.start)
                let end = CMTimeGetSeconds(result.range.end)
                let raw = String(result.text.characters)
                let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(.init(start: start, end: end, text: text))
                if duration > 0 {
                    onProgress?(min(1.0, end / duration))
                }
            }
            return segments
        }

        do {
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        } catch {
            collectionTask.cancel()
            throw error
        }

        let segments = try await collectionTask.value
        onProgress?(1.0)
        return segments
    }
}

/// User-facing errors from the SpeechAnalyzer backend. Rendered in alerts via
/// `errorDescription`, so messages should describe the fix (usually: switch to
/// WhisperKit) rather than the internal cause.
enum SpeechAnalyzerError: LocalizedError {
    case unsupportedOS
    case unsupportedLocale(String)
    case assetsUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Apple SpeechAnalyzer requires macOS 26 (Tahoe) or later. "
                + "Switch to Local (WhisperKit) in Settings → Transcription, "
                + "or upgrade macOS."
        case let .unsupportedLocale(id):
            return "Apple SpeechAnalyzer does not support the locale \"\(id)\". "
                + "Hebrew and many other languages are not available yet — "
                + "switch to Local (WhisperKit) in Settings → Transcription "
                + "for these languages."
        case .assetsUnavailable:
            return "Could not download the SpeechAnalyzer model for this "
                + "locale. Check your network connection and try again, or "
                + "switch to Local (WhisperKit)."
        }
    }
}
