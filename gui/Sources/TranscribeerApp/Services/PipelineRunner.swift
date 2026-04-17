import Foundation
import os.log

private let logger = Logger(subsystem: "com.transcribeer", category: "pipeline")

/// Appends timestamped lines to a session's `run.log` file.
private struct SessionLogger {
    let logPath: URL

    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(
            from: Date(),
            dateStyle: .none,
            timeStyle: .medium
        )
        let data = Data("[\(timestamp)] \(message)\n".utf8)

        if let handle = try? FileHandle(forWritingTo: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logPath)
        }
    }
}

/// Runs the transcribeer pipeline using native Swift services.
@Observable
@MainActor
final class PipelineRunner {
    var state: AppState = .idle
    var currentSession: URL?
    var promptProfile: String?

    /// True when the current recording was auto-started by Zoom detection.
    var zoomAutoStarted = false

    /// Which session is actively being transcribed right now, if any.
    /// Set for both new recordings and re-transcribe-from-history flows so
    /// the detail view can decide whether to render the live preview.
    var transcribingSession: URL?

    /// Which session is actively being summarized right now, if any. Drives
    /// the live markdown preview while the LLM streams deltas.
    var summarizingSession: URL?

    /// Running accumulator of streamed summary text for `summarizingSession`.
    /// Cleared when the stream finishes or a new summary starts.
    var liveSummary: String = ""

    /// Transcription progress (0..1), driven by WhisperKit.
    var transcriptionProgress: Double? { transcriptionService.progress }

    let transcriptionService = TranscriptionService()

    private var captureProcess: Process?
    private var pipelineTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var summarizeTask: Task<CLIResult, Never>?

    func startRecording(config: AppConfig) {
        guard !state.isBusy else { return }

        let session = SessionManager.newSession(sessionsDir: config.expandedSessionsDir)
        currentSession = session
        promptProfile = nil
        state = .recording(startTime: Date())

        pipelineTask = Task {
            await runPipeline(session: session, config: config)
        }
    }

    func stopRecording() {
        guard state.isRecording else { return }
        if let captureProcess, captureProcess.isRunning {
            captureProcess.interrupt()  // SIGINT
        }
    }

    /// Cancel an in-flight transcription or summarization. Does nothing while
    /// recording (use `stopRecording` for that).
    func cancelProcessing() {
        switch state {
        case .transcribing, .summarizing:
            transcriptionService.cancel()
            processingTask?.cancel()
            pipelineTask?.cancel()
            summarizeTask?.cancel()
            summarizeTask = nil
        default:
            break
        }
    }

    private func runPipeline(session: URL, config: AppConfig) async {
        let audioPath = session.appendingPathComponent("audio.m4a")
        let transcriptPath = session.appendingPathComponent("transcript.txt")
        let summaryPath = session.appendingPathComponent("summary.md")
        let logger = SessionLogger(logPath: session.appendingPathComponent("run.log"))

        logger.log("session=\(session.path)")
        logger.log("pipeline=\(config.pipelineMode) lang=\(config.language) diarize=\(config.diarization)")

        // 1. Record — use capture-bin directly
        logger.log("capture-bin=\(config.expandedCaptureBin)")
        guard await performRecording(config: config, audioPath: audioPath, logger: logger) else {
            return
        }

        if config.pipelineMode == "record-only" {
            finishSession(session)
            return
        }

        // 2. Transcribe (WhisperKit + SpeakerKit)
        guard await performTranscription(
            config: config,
            audioPath: audioPath,
            transcriptPath: transcriptPath,
            logger: logger
        ) else { return }

        if config.pipelineMode == "record+transcribe" {
            finishSession(session)
            return
        }

        // 3. Summarize (LLM) — failure here is non-fatal
        await performSummarization(
            config: config,
            transcriptPath: transcriptPath,
            summaryPath: summaryPath,
            logger: logger
        )

        finishSession(session)
    }

    private func performRecording(
        config: AppConfig,
        audioPath: URL,
        logger: SessionLogger
    ) async -> Bool {
        let result = await runCapture(
            captureBin: config.expandedCaptureBin,
            audioPath: audioPath
        )

        switch result {
        case let .error(err):
            logger.log("capture failed: \(err)")
            state = .error(err)
            NotificationManager.notifyError(err)
            return false
        case .noAudio:
            logger.log("no audio captured")
            state = .idle
            return false
        case .recorded:
            let size = (try? FileManager.default.attributesOfItem(
                atPath: audioPath.path,
            )[.size] as? Int) ?? 0
            logger.log("recorded \(size) bytes")
            return true
        }
    }

    private func performTranscription(
        config: AppConfig,
        audioPath: URL,
        transcriptPath: URL,
        logger: SessionLogger,
    ) async -> Bool {
        state = .transcribing
        transcribingSession = transcriptPath.deletingLastPathComponent()
        defer { transcribingSession = nil }
        logger.log("transcription started")
        do {
            let result = try await transcribeAndFormat(
                audioPath: audioPath,
                language: config.language,
                model: config.whisperModel,
                diarization: config.diarization,
                numSpeakers: config.numSpeakers,
            )
            try result.write(to: transcriptPath, atomically: true, encoding: .utf8)
            SessionManager.setLanguage(transcriptPath.deletingLastPathComponent(), config.language)
            logger.log("transcription done")
            return true
        } catch is CancellationError {
            logger.log("transcription cancelled")
            state = .idle
            return false
        } catch {
            let message = "Transcription failed: \(error.localizedDescription)"
            logger.log(message)
            state = .error(message)
            NotificationManager.notifyError(message)
            return false
        }
    }

    private func performSummarization(
        config: AppConfig,
        transcriptPath: URL,
        summaryPath: URL,
        logger: SessionLogger
    ) async {
        state = .summarizing
        logger.log("summarization started backend=\(config.llmBackend) model=\(config.llmModel) profile=\(promptProfile ?? "default")")
        do {
            let transcript = try String(contentsOf: transcriptPath, encoding: .utf8)
            let customPrompt = SummarizationService.loadPromptProfile(promptProfile)
            _ = try await streamSummary(
                session: transcriptPath.deletingLastPathComponent(),
                transcript: transcript,
                summaryPath: summaryPath,
                config: config,
                prompt: customPrompt,
            )
            logger.log("summarization done")
        } catch {
            logger.log("summarization failed: \(error.localizedDescription)")
            // Non-fatal — transcript is what matters.
        }
    }

    /// Stream summary deltas from the LLM, mirroring them into `liveSummary`
    /// for the detail view to render in real time. Writes the final text to
    /// `summaryPath` before clearing the live state, so there is no flash of
    /// stale disk content between stream-end and the caller's reload.
    private func streamSummary(
        session: URL,
        transcript: String,
        summaryPath: URL,
        config: AppConfig,
        prompt: String?,
    ) async throws -> String {
        summarizingSession = session
        liveSummary = ""
        // Clear on any exit path — success, throw, or cancellation.
        defer {
            summarizingSession = nil
            liveSummary = ""
        }

        let stream = try await SummarizationService.streamSummarize(
            transcript: transcript,
            backend: config.llmBackend,
            model: config.llmModel,
            ollamaHost: config.ollamaHost,
            prompt: prompt,
        )

        var accumulated = ""
        for try await fragment in stream {
            try Task.checkCancellation()
            accumulated += fragment
            liveSummary = accumulated
        }
        try accumulated.write(to: summaryPath, atomically: true, encoding: .utf8)
        return accumulated
    }

    private func finishSession(_ session: URL) {
        state = .done(sessionPath: session.path)
        NotificationManager.notifyDone(sessionName: SessionManager.displayName(session))
    }

    // MARK: - Transcription + Diarization + Formatting

    private func transcribeAndFormat(
        audioPath: URL,
        language: String,
        model: String,
        diarization: String,
        numSpeakers: Int,
    ) async throws -> String {
        // Ensure the configured model is loaded. Runs on the service's
        // MainActor but quickly hands off to a background task for the
        // expensive compile/prewarm steps WhisperKit performs internally.
        try await transcriptionService.loadModel(name: model)

        // Transcription and diarization are independent: both consume the
        // same audio file and produce disjoint segment streams. Run them in
        // parallel so the pipeline's wall time is dominated by the slower of
        // the two instead of their sum.
        async let whisperSegmentsTask = transcriptionService.transcribe(
            audioURL: audioPath,
            language: language,
        )

        async let diarSegmentsTask: [DiarSegment] = {
            guard diarization != "none" else { return [] }
            return try await DiarizationService.diarize(
                audioURL: audioPath,
                numSpeakers: numSpeakers > 0 ? numSpeakers : nil,
            )
        }()

        let whisperSegments = try await whisperSegmentsTask
        let diarSegments = try await diarSegmentsTask

        try Task.checkCancellation()

        let labeled = TranscriptFormatter.assignSpeakers(
            whisperSegments: whisperSegments,
            diarSegments: diarSegments,
        )
        return TranscriptFormatter.format(labeled)
    }

    // MARK: - Capture

    private enum CaptureResult {
        case recorded
        case noAudio
        case error(String)
    }

    private func runCapture(captureBin: String, audioPath: URL) async -> CaptureResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: captureBin)
                proc.arguments = [audioPath.path]
                let errPipe = Pipe()
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = errPipe

                do {
                    try proc.run()
                } catch {
                    continuation.resume(returning: .error(
                        "Failed to launch capture-bin: \(error.localizedDescription)"
                    ))
                    return
                }

                Task { @MainActor in
                    self?.captureProcess = proc
                }

                proc.waitUntilExit()

                Task { @MainActor in
                    self?.captureProcess = nil
                }

                let stderr = String(
                    data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""

                if proc.terminationStatus != 0 {
                    if stderr.contains("Screen & System Audio Recording") {
                        continuation.resume(returning: .error(
                            "Grant Screen Recording in System Settings → Privacy"
                        ))
                    } else {
                        continuation.resume(returning: .error(
                            "capture-bin exited \(proc.terminationStatus)"
                        ))
                    }
                    return
                }

                let size = (try? FileManager.default.attributesOfItem(
                    atPath: audioPath.path
                )[.size] as? UInt64) ?? 0
                continuation.resume(returning: size > 0 ? .recorded : .noAudio)
            }
        }
    }

    // MARK: - History re-runs

    /// Result of a pipeline operation.
    struct CLIResult {
        let ok: Bool
        let error: String
    }

    /// Re-transcribe a session from its audio.
    ///
    /// `languageOverride` wins over `config.language` when non-nil. Used by the
    /// session detail view to run Hebrew on one recording while the global
    /// default stays on English (or auto).
    func transcribeSession(
        _ session: URL,
        config: AppConfig,
        languageOverride: String? = nil,
    ) async -> CLIResult {
        guard let audioPath = SessionManager.audioURL(in: session) else {
            return CLIResult(ok: false, error: "Audio file not found")
        }
        let txPath = session.appendingPathComponent("transcript.txt")
        let language = languageOverride ?? config.language

        logger.info("re-transcribe: \(audioPath.path) lang=\(language)")

        let previousState = state
        state = .transcribing
        transcribingSession = session
        defer {
            transcribingSession = nil
            if case .transcribing = state { state = previousState }
        }

        do {
            let result = try await transcribeAndFormat(
                audioPath: audioPath,
                language: language,
                model: config.whisperModel,
                diarization: config.diarization,
                numSpeakers: config.numSpeakers,
            )
            try result.write(to: txPath, atomically: true, encoding: .utf8)
            SessionManager.setLanguage(session, language)
            return CLIResult(ok: true, error: "")
        } catch is CancellationError {
            logger.info("re-transcribe cancelled")
            return CLIResult(ok: false, error: "Cancelled")
        } catch {
            logger.error("re-transcribe failed: \(error.localizedDescription)")
            return CLIResult(ok: false, error: error.localizedDescription)
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
        overrides: SummarizeOverrides = .init(),
    ) async -> CLIResult {
        let txPath = session.appendingPathComponent("transcript.txt")
        let smPath = session.appendingPathComponent("summary.md")

        guard FileManager.default.fileExists(atPath: txPath.path) else {
            return CLIResult(ok: false, error: "Transcript file not found")
        }

        let effectiveConfig = applyOverrides(overrides, to: config)
        logger.info(
            "re-summarize: \(txPath.path) backend=\(effectiveConfig.llmBackend) model=\(effectiveConfig.llmModel)",
        )

        let previousState = state
        state = .summarizing

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
                    prompt: prompt,
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
        if case .summarizing = state { state = previousState }

        if !result.ok, result.error == "Cancelled" {
            logger.info("re-summarize cancelled")
        } else if !result.ok {
            logger.error("re-summarize failed: \(result.error)")
        }
        return result
    }

    /// Produce a config with backend/model swapped when the caller supplied
    /// overrides. Keeps the original config untouched so the user's saved
    /// preferences aren't mutated by a one-off regenerate.
    private func applyOverrides(_ overrides: SummarizeOverrides, to config: AppConfig) -> AppConfig {
        var copy = config
        if let backend = overrides.backend, !backend.isEmpty {
            copy.llmBackend = backend
        }
        if let model = overrides.model, !model.isEmpty {
            copy.llmModel = model
        }
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
