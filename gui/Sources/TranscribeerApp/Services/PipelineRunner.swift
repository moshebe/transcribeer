import Foundation
import os.log
import TranscribeerCore

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

    /// Context captured when meeting detection auto-starts a recording.
    /// Populated before `startRecording(config:)` is called by the app layer;
    /// surfaced in the session run log so auto-started sessions can be
    /// distinguished from manual ones later.
    struct MeetingAutoStartContext: Equatable {
        var appName: String
        var title: String?
        var delaySeconds: Int
    }

    /// Non-nil when the current recording was auto-started by meeting detection.
    var meetingAutoStartContext: MeetingAutoStartContext?

    /// True when the current recording was auto-started by meeting detection.
    var meetingAutoStarted: Bool { meetingAutoStartContext != nil }

    /// Which session is actively being transcribed right now, if any.
    /// Set for both new recordings and re-transcribe-from-history flows so
    /// the detail view can decide whether to render the live preview.
    var transcribingSession: URL?

    /// Which session is actively being summarized right now, if any. Drives
    /// the live markdown preview while the LLM streams deltas.
    var summarizingSession: URL?

    /// Running accumulator of streamed summary text for `summarizingSession`.
    /// Cleared when the stream finishes or a new summary starts.
    var liveSummary = ""

    /// Transcription progress (0..1), driven by WhisperKit.
    var transcriptionProgress: Double? { transcriptionService.progress }

    /// True between a user clicking Stop and the pipeline actually tearing
    /// down. Drives a "Cancelling…" UI state so the button feels responsive
    /// even while WhisperKit finishes a non-cancellable CoreML load.
    var isCancelling = false

    let transcriptionService = TranscriptionService()

    /// Observable source of meeting participants scraped from Zoom's UI.
    /// Kept as a property so the UI layer can read `.snapshot` for live state.
    /// Started/stopped in lock-step with recording to avoid background AX
    /// traffic when idle.
    let participantsWatcher = ZoomParticipantsWatcher()

    /// Latest Zoom meeting topic observed while recording. `nil` when not
    /// recording, the enricher is disabled, or Zoom has no detectable topic.
    /// Refreshed every ~2 s by `titlePollTask` so the UI reflects topic edits
    /// that land mid-call.
    private(set) var liveMeetingTitle: String?

    private var pipelineTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var summarizeTask: Task<CLIResult, Never>?
    /// Active participants recorder for the current session, `nil` when idle.
    private var participantsRecorder: SessionParticipantsRecorder?
    private var titlePollTask: Task<Void, Never>?

    /// Append a timestamped line to the current session's `run.log`. No-op
    /// when no session is active. Used by the app layer to record events that
    /// happen outside `runPipeline`, e.g. meeting-driven auto-stop.
    func appendRunLog(_ message: String) {
        guard let session = currentSession else { return }
        SessionLogger(logPath: session.appendingPathComponent("run.log")).log(message)
    }

    func startRecording(config: AppConfig) {
        guard !state.isBusy else { return }

        let session = SessionManager.newSession(sessionsDir: config.expandedSessionsDir)
        currentSession = session
        promptProfile = nil
        isCancelling = false
        let startTime = Date()
        // Persist start time immediately so it’s visible in the sidebar
        // while the recording is still in progress.
        SessionManager.setRecordingTimes(session, startedAt: startTime, endedAt: nil)
        startParticipantsCapture(for: session, config: config)
        startTitlePolling(config: config)
        state = .recording(startTime: startTime)

        pipelineTask = Task {
            await runPipeline(session: session, startedAt: startTime, config: config)
        }
    }

    /// Spin up participant observation for the given session. Started at the
    /// top of `startRecording` so even the early moments of a meeting are
    /// captured. Torn down from every path that ends the recording.
    ///
    /// No-op when the Zoom enricher is disabled in `config` or when the
    /// participant cap is set to 0 — avoids background AX polling for users
    /// who have opted out.
    private func startParticipantsCapture(for session: URL, config: AppConfig) {
        guard config.zoomEnricherEnabled, config.maxMeetingParticipants > 0 else {
            logger.info("zoom enricher disabled (enabled=\(config.zoomEnricherEnabled) cap=\(config.maxMeetingParticipants)) — skipping participant capture")
            return
        }
        participantsWatcher.start()
        let recorder = SessionParticipantsRecorder(
            session: session,
            watcher: participantsWatcher,
            maxParticipants: config.maxMeetingParticipants,
        )
        participantsRecorder = recorder
        recorder.start()
    }

    private func stopParticipantsCapture() {
        participantsRecorder?.stop()
        participantsRecorder = nil
        participantsWatcher.stop()
        stopTitlePolling()
    }

    /// Poll the Zoom AX topic every 2 s while recording so the UI reflects
    /// late-arriving topics and mid-call edits. No-op when the Zoom enricher
    /// is disabled — same contract as `startParticipantsCapture`.
    ///
    /// Once a non-nil title is observed it is sticky for the rest of the
    /// session: later polls that return nil (e.g. the meeting window closed
    /// before recording stops) do not wipe the UI label.
    private func startTitlePolling(config: AppConfig) {
        guard config.zoomEnricherEnabled else { return }
        titlePollTask?.cancel()
        titlePollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let title = ZoomTitleReader.meetingTitle() {
                    self?.liveMeetingTitle = title
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func stopTitlePolling() {
        titlePollTask?.cancel()
        titlePollTask = nil
        liveMeetingTitle = nil
    }

    func stopRecording() {
        guard state.isRecording else { return }
        CaptureService.stop()
    }

    /// Cancel an in-flight transcription or summarization. Does nothing while
    /// recording (use `stopRecording` for that).
    ///
    /// Cancellation is cooperative: `pipelineTask.cancel()` propagates through
    /// the structured task tree, and WhisperKit / HubApi check
    /// `Task.isCancelled` at various checkpoints. The CoreML model compile +
    /// prewarm step has no cancellation hook, so during that phase the pipeline
    /// keeps running until it reaches the next checkpoint — we set
    /// `isCancelling` immediately so the UI can reflect that a stop is pending.
    func cancelProcessing() {
        switch state {
        case .transcribing, .summarizing:
            isCancelling = true
            transcriptionService.cancel()
            processingTask?.cancel()
            pipelineTask?.cancel()
            summarizeTask?.cancel()
            summarizeTask = nil
        default:
            break
        }
    }

    private func runPipeline(session: URL, startedAt: Date, config: AppConfig) async {
        let audioPath = session.appendingPathComponent("audio.m4a")
        let transcriptPath = session.appendingPathComponent("transcript.txt")
        let summaryPath = session.appendingPathComponent("summary.md")
        let logger = SessionLogger(logPath: session.appendingPathComponent("run.log"))

        logger.log("session=\(session.path)")
        logger.log("pipeline=\(config.pipelineMode) lang=\(config.language) diarize=\(config.diarization)")
        for line in CaptureService.describeDevices(audio: config.audio) {
            logger.log(line)
        }
        if let ctx = meetingAutoStartContext {
            let titlePart = ctx.title.map { "title=\"\($0)\"" } ?? "title=<none>"
            logger.log(
                "start=auto meeting.app=\(ctx.appName) \(titlePart) delay=\(ctx.delaySeconds)s"
            )
        } else {
            logger.log("start=manual")
        }

        // 1. Record — in-process via CaptureCore (uses app's TCC permission)
        logger.log("capture started")
        let recordResult = await CaptureService.record(
            to: session,
            duration: nil,
            audio: config.audio
        )

        switch recordResult {
        case .permissionDenied(let detail):
            stopParticipantsCapture()
            reportFailure("capture failed: \(detail)", userFacing: detail, logger: logger)
            return
        case .error(let err):
            stopParticipantsCapture()
            reportFailure("capture failed: \(err)", userFacing: err, logger: logger)
            return
        case .noAudio:
            stopParticipantsCapture()
            logger.log("no audio captured")
            state = .idle
            return
        case .recorded:
            let size = (try? FileManager.default.attributesOfItem(
                atPath: audioPath.path
            )[.size] as? UInt64) ?? 0
            logger.log("recorded \(size) bytes")
            // Stamp the wall-clock end of the capture so the sidebar can
            // show a "10:30 – 11:15" range for calendar correlation.
            SessionManager.setRecordingTimes(session, startedAt: startedAt, endedAt: Date())
        }

        if config.pipelineMode == "record-only" {
            finishSession(session)
            return
        }

        // 2. Transcribe (WhisperKit + SpeakerKit)
        guard await performTranscription(
            config: config,
            session: session,
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

    /// Log a failure message, flip state to `.error`, and post a user notification.
    private func reportFailure(_ logMessage: String, userFacing: String, logger: SessionLogger) {
        logger.log(logMessage)
        state = .error(userFacing)
        NotificationManager.notifyError(userFacing)
    }

    private func performTranscription(
        config: AppConfig,
        session: URL,
        transcriptPath: URL,
        logger: SessionLogger
    ) async -> Bool {
        state = .transcribing
        transcribingSession = session
        defer { transcribingSession = nil }
        logger.log("transcription started")

        do {
            let result = try await transcriptionService.transcribe(
                session: session,
                config: config
            )
            try result.write(to: transcriptPath, atomically: true, encoding: .utf8)
            SessionManager.setLanguage(session, config.language)
            logger.log("transcription done")
            return true
        } catch is CancellationError {
            logger.log("transcription cancelled")
            stopParticipantsCapture()
            isCancelling = false
            state = .idle
            return false
        } catch {
            stopParticipantsCapture()
            let message = "Transcription failed: \(error.localizedDescription)"
            reportFailure(message, userFacing: message, logger: logger)
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
                prompt: customPrompt
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
        prompt: String?
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
            prompt: prompt
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
        stopParticipantsCapture()
        state = .done(sessionPath: session.path)
        NotificationManager.notifyDone(sessionName: SessionManager.displayName(session))
    }

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

        logger.info(
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
            return CLIResult(ok: true, error: "")
        } catch is CancellationError {
            logger.info("re-transcribe cancelled")
            appendSessionLog(session, "re-transcribe cancelled")
            return CLIResult(ok: false, error: "Cancelled")
        } catch {
            let detail = error.localizedDescription
            logger.error(
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
    private func appendSessionLog(_ session: URL, _ message: String) {
        SessionLogger(
            logPath: session.appendingPathComponent("run.log")
        ).log(message)
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
        logger.info(
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
            logger.info("re-summarize cancelled")
            appendSessionLog(session, "re-summarize cancelled")
        } else if !result.ok {
            logger.error("re-summarize failed: \(result.error, privacy: .public)")
            appendSessionLog(session, "re-summarize failed: \(result.error)")
        }
        return result
    }

    /// Produce a config with backend/model swapped when the caller supplied
    /// overrides. Keeps the original config untouched so the user's saved
    /// preferences aren't mutated by a one-off regenerate.
    private func applyOverrides(_ overrides: SummarizeOverrides, to config: AppConfig) -> AppConfig {
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
