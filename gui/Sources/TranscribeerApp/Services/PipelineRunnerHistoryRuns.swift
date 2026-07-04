import Foundation
import os.log
import TranscribeerCore

private let historyLogger = Logger(subsystem: "com.transcribeer", category: "pipeline")

/// History re-run operations: re-transcribe and re-summarize from existing sessions.
/// Extracted into a separate file to keep `PipelineRunner` within the type-body-length limit.
extension PipelineRunner {
    // MARK: - History re-runs

    /// Result of a pipeline operation.
    struct CLIResult {
        let ok: Bool
        let error: String
    }

    /// Re-transcribe a session from its audio.
    ///
    /// `languageOverride` wins over `config.language` when non-nil; same
    /// for `backendOverride` against `config.transcriptionBackend`. The
    /// detail view uses these to run a one-off transcription in a different
    /// language or with a different backend (e.g. fall back to OpenAI for a
    /// recording WhisperKit struggled with) without touching the global
    /// config.
    func transcribeSession(
        _ session: URL,
        config: AppConfig,
        languageOverride: String? = nil,
        backendOverride: String? = nil
    ) async -> CLIResult {
        let txPath = session.appendingPathComponent("transcript.txt")
        var cfg = config
        if let languageOverride {
            cfg.language = languageOverride
        }
        if let backendOverride, !backendOverride.isEmpty {
            cfg.transcriptionBackend = backendOverride
        }

        historyLogger.info(
            """
            re-transcribe: \(session.path, privacy: .public) \
            lang=\(cfg.language, privacy: .public) \
            backend=\(cfg.transcriptionBackend, privacy: .public)
            """
        )
        appendSessionLog(
            session,
            "re-transcribe start lang=\(cfg.language) backend=\(cfg.transcriptionBackend)"
        )

        let previousState = state
        state = .transcribing
        transcribingSession = session
        isCancelling = false
        defer {
            transcribingSession = nil
            isCancelling = false
            if case .transcribing = state { state = previousState }
        }

        do {
            let result = try await transcriptionService.transcribe(
                session: session,
                config: cfg
            )
            try result.write(to: txPath, atomically: true, encoding: .utf8)
            SessionManager.setLanguage(session, cfg.language)
            if let detected = transcriptionService.lastDetectedLanguage {
                SessionManager.setDetectedLanguage(session, detected)
            } else if cfg.language != "auto" {
                // Explicit language override — clear any previous auto-detection so
                // the chip doesn't show a stale value after a manual re-transcribe.
                SessionManager.setDetectedLanguage(session, nil)
            }
            return CLIResult(ok: true, error: "")
        } catch is CancellationError {
            historyLogger.info("re-transcribe cancelled")
            appendSessionLog(session, "re-transcribe cancelled")
            return CLIResult(ok: false, error: "Cancelled")
        } catch {
            let detail = error.localizedDescription
            historyLogger.error(
                """
                re-transcribe failed: \(detail, privacy: .public) \
                type=\(String(reflecting: type(of: error)), privacy: .public) \
                raw=\(String(reflecting: error), privacy: .public)
                """
            )
            appendSessionLog(session, "re-transcribe failed: \(detail)")
            return CLIResult(ok: false, error: detail)
        }
    }

    /// Append a line to the given session's `run.log`. Used by re-run paths
    /// so the per-session log captures retries and their failures without
    /// requiring users to spelunk `log show`.
    func appendSessionLog(_ session: URL, _ message: String) {
        let logPath = session.appendingPathComponent("run.log")
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let data = Data("[\(timestamp)] \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }

    /// Optional one-shot overrides for a single re-summarize call.
    ///
    /// `backend`/`model` let the detail view pick a different LLM without
    /// touching the global config. `focus` is a free-form user note appended
    /// to the system prompt — typically "focus on X" — so people can steer
    /// a summary towards a topic without creating a new prompt profile.
    struct SummarizeOverrides {
        var backend: String?
        var model: String?
        var focus: String?
    }

    /// Re-summarize a session from its transcript.
    func summarizeSession(
        _ session: URL,
        config: AppConfig,
        profile: String?,
        overrides: SummarizeOverrides = .init()
    ) async -> CLIResult {
        let txPath = session.appendingPathComponent("transcript.txt")
        let smPath = session.appendingPathComponent("summary.md")

        guard FileManager.default.fileExists(atPath: txPath.path) else {
            return CLIResult(ok: false, error: "Transcript file not found")
        }

        let effectiveConfig = applyOverrides(overrides, to: config)
        historyLogger.info(
            "re-summarize: \(txPath.path) backend=\(effectiveConfig.llmBackend) model=\(effectiveConfig.llmModel)"
        )

        let previousState = state
        state = .summarizing
        isCancelling = false

        // Run inside a stored Task so `cancelProcessing` can tear it down
        // mid-stream — the caller's Task isn't reachable from the runner.
        let work: Task<CLIResult, Never> = Task { [weak self] in
            guard let self else { return CLIResult(ok: false, error: "Cancelled") }
            do {
                let transcript = try String(contentsOf: txPath, encoding: .utf8)
                let basePrompt = SummarizationService.loadPromptProfile(profile)
                let prompt = Self.composePrompt(base: basePrompt, focus: overrides.focus)
                _ = try await self.streamSummary(
                    session: session,
                    transcript: transcript,
                    summaryPath: smPath,
                    config: effectiveConfig,
                    prompt: prompt
                )
                return CLIResult(ok: true, error: "")
            } catch is CancellationError {
                return CLIResult(ok: false, error: "Cancelled")
            } catch {
                return CLIResult(ok: false, error: error.localizedDescription)
            }
        }
        summarizeTask = work
        let result = await work.value
        summarizeTask = nil
        isCancelling = false
        if case .summarizing = state { state = previousState }

        if !result.ok, result.error == "Cancelled" {
            historyLogger.info("re-summarize cancelled")
            appendSessionLog(session, "re-summarize cancelled")
        } else if !result.ok {
            historyLogger.error("re-summarize failed: \(result.error, privacy: .public)")
            appendSessionLog(session, "re-summarize failed: \(result.error)")
        }
        return result
    }

    /// Produce a config with backend/model swapped when the caller supplied
    /// overrides. Keeps the original config untouched so the user's saved
    /// preferences aren't mutated by a one-off regenerate.
    func applyOverrides(_ overrides: SummarizeOverrides, to config: AppConfig) -> AppConfig {
        var copy = config
        if let backend = overrides.backend, !backend.isEmpty { copy.llmBackend = backend }
        if let model = overrides.model, !model.isEmpty { copy.llmModel = model }
        return copy
    }

    /// Combine the profile prompt (or the built-in default) with an optional
    /// free-form focus instruction. Returns `nil` when there's nothing to
    /// override — the service will fall back to `defaultPrompt`.
    static func composePrompt(base: String?, focus: String?) -> String? {
        let trimmedFocus = focus?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedFocus, !trimmedFocus.isEmpty {
            let root = base ?? SummarizationService.defaultPrompt
            return root + "\n\nAdditional instructions from the user:\n" + trimmedFocus
        }
        return base
    }
}
