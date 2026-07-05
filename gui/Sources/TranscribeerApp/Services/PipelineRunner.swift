import AVFoundation
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

    // MARK: - Track 4.3: Post-recording prompt

    /// Non-nil while waiting for the user to pick a post-recording action.
    /// The sheet observes this alongside `state == .awaitingPostRecordingChoice`.
    private(set) var postRecordingSessionName: String?
    /// Duration of the captured audio, set alongside `awaitingPostRecordingChoice`.
    private(set) var postRecordingDuration: TimeInterval = 0
    @ObservationIgnored private var postRecordingContinuation: CheckedContinuation<PostRecordingChoice, Never>?

    // MARK: - Track 4.5: Long-recording confirmation

    /// Non-nil while waiting for the user to confirm summarization of a long recording.
    private(set) var pendingLongRecordingDuration: TimeInterval?
    @ObservationIgnored private var longRecordingContinuation: CheckedContinuation<Bool, Never>?

    private var pipelineTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    var summarizeTask: Task<CLIResult, Never>?
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
        case .awaitingPostRecordingChoice:
            resolvePostRecordingChoice(.saveOnly)
        case .awaitingLongRecordingConfirmation:
            confirmLongRecording(false)
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
            finishSession(session, config: config)
            return
        }

        // Track 4.3 — prompt-on-stop: ask user what to do before running pipeline.
        // Returns false when the choice handled the pipeline end (discard/save/transcribe-only).
        if config.promptOnStop {
            let shouldContinue = await handlePostRecordingPrompt(
                session: session,
                transcriptPath: transcriptPath,
                config: config,
                logger: logger
            )
            guard shouldContinue else { return }
        }

        // 2. Transcribe (WhisperKit + SpeakerKit)
        guard await performTranscription(
            config: config,
            session: session,
            transcriptPath: transcriptPath,
            logger: logger
        ) else { return }

        if config.pipelineMode == "record+transcribe" {
            finishSession(session, config: config)
            return
        }

        // 3. Summarize (LLM) — failure here is non-fatal
        await performSummarization(
            config: config,
            transcriptPath: transcriptPath,
            summaryPath: summaryPath,
            session: session,
            logger: logger
        )

        finishSession(session, config: config)
    }

    // MARK: - Track 4.3 post-recording prompt

    /// Suspends the pipeline until the user picks an action.
    /// Returns `true` if the pipeline should proceed to transcription+summarization,
    /// `false` if the choice already terminated the pipeline (discard/save/transcribe-only).
    private func handlePostRecordingPrompt(
        session: URL,
        transcriptPath: URL,
        config: AppConfig,
        logger: SessionLogger
    ) async -> Bool {
        let name = SessionManager.displayName(session)
        let audioURL = session.appendingPathComponent("audio.m4a")
        let duration: TimeInterval
        if let asset = try? await AVURLAsset(url: audioURL).load(.duration) {
            duration = asset.seconds
        } else {
            duration = 0
        }

        let choice = await withCheckedContinuation { (cont: CheckedContinuation<PostRecordingChoice, Never>) in
            postRecordingContinuation = cont
            postRecordingSessionName = name
            postRecordingDuration = duration
            state = .awaitingPostRecordingChoice
        }

        postRecordingSessionName = nil
        postRecordingDuration = 0

        switch choice {
        case .discard:
            logger.log("post-recording: discard")
            stopParticipantsCapture()
            try? FileManager.default.removeItem(at: session)
            state = .idle
            return false
        case .saveOnly:
            logger.log("post-recording: save-only")
            finishSession(session, config: config)
            return false
        case .transcribeOnly:
            logger.log("post-recording: transcribe-only")
            guard await performTranscription(
                config: config,
                session: session,
                transcriptPath: transcriptPath,
                logger: logger
            ) else { return false }
            finishSession(session, config: config)
            return false
        case .transcribeAndSummarize:
            logger.log("post-recording: transcribe-and-summarize")
            return true
        }
    }

    // MARK: - Track 4.3 resolution

    /// Called from the PostRecordingSheet to resolve the awaited continuation.
    func resolvePostRecordingChoice(_ choice: PostRecordingChoice) {
        postRecordingContinuation?.resume(returning: choice)
        postRecordingContinuation = nil
    }

    // MARK: - Track 4.5 resolution

    /// Called from the LongRecordingConfirmationSheet to resolve the awaited continuation.
    func confirmLongRecording(_ shouldSummarize: Bool) {
        pendingLongRecordingDuration = nil
        longRecordingContinuation?.resume(returning: shouldSummarize)
        longRecordingContinuation = nil
    }

    // MARK: - Failure reporting

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

        let startedAt = Date()
        do {
            let result = try await transcriptionService.transcribe(
                session: session,
                config: config
            )
            try result.write(to: transcriptPath, atomically: true, encoding: .utf8)
            SessionManager.setLanguage(session, config.language)
            if let detected = transcriptionService.lastDetectedLanguage {
                SessionManager.setDetectedLanguage(session, detected)
            }
            SessionUsageRecorder.recordTranscription(
                session: session,
                config: config,
                duration: Date().timeIntervalSince(startedAt),
            )
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
        session: URL,
        logger: SessionLogger
    ) async {
        // Track 4.5 — long-recording confirmation gate
        if config.longRecordingThresholdMinutes > 0 {
            let audioURL = session.appendingPathComponent("audio.m4a")
            if let cmDuration = try? await AVURLAsset(url: audioURL).load(.duration) {
                let seconds = cmDuration.seconds
                let thresholdSeconds = Double(config.longRecordingThresholdMinutes) * 60
                if seconds > thresholdSeconds {
                    let shouldSummarize = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                        longRecordingContinuation = cont
                        pendingLongRecordingDuration = seconds
                        state = .awaitingLongRecordingConfirmation
                    }
                    if !shouldSummarize {
                        logger.log("long-recording: user skipped summarization")
                        return
                    }
                    logger.log("long-recording: user confirmed summarization")
                }
            }
        }

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
    func streamSummary(
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

        let startedAt = Date()
        let stream = try await SummarizationService.streamSummarize(
            transcript: transcript,
            backend: config.llmBackend,
            model: config.llmModel,
            ollamaHost: config.ollamaHost,
            prompt: prompt
        )

        var accumulated = ""
        var tokenUsage: TokenUsage?
        for try await event in stream {
            try Task.checkCancellation()
            switch event {
            case let .textDelta(fragment):
                accumulated += fragment
                liveSummary = accumulated
            case let .completed(usage):
                tokenUsage = usage
            }
        }
        try accumulated.write(to: summaryPath, atomically: true, encoding: .utf8)
        SessionUsageRecorder.recordSummarization(
            session: session,
            config: config,
            usage: tokenUsage,
            duration: Date().timeIntervalSince(startedAt),
        )
        await SessionDescriptionWriter.write(session: session, summary: accumulated, config: config)
        return accumulated
    }

    private func finishSession(_ session: URL, config: AppConfig) {
        stopParticipantsCapture()
        state = .done(sessionPath: session.path)
        NotificationManager.notifyDone(sessionName: SessionManager.displayName(session))
        Task {
            await IntegrationDispatcher.dispatch(session: session, config: config)
        }
    }
}
