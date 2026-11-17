import Foundation
import os.log

private let logger = Logger(subsystem: "com.transcribeer", category: "pipeline-queue")

/// One unit of transcription / summarization work, with the config it runs
/// under. Every job that uses the transcription service or the summarizer
/// goes through the queue, so two never run at the same time.
struct QueuedSession: Identifiable {
    enum Job {
        /// A finished recording. What to do with it was decided when the
        /// recording stopped (post-recording prompt, long-recording check),
        /// so the job itself never waits for the user.
        case recording(summarize: Bool)
        /// Re-transcribe from history or the nightly batch.
        case transcribe(languageOverride: String?, backendOverride: String?)
        /// Re-summarize from history or the nightly batch.
        case summarize(profile: String?, overrides: PipelineRunner.SummarizeOverrides)

        enum Kind { case recording, transcribe, summarize }

        var kind: Kind {
            switch self {
            case .recording: .recording
            case .transcribe: .transcribe
            case .summarize: .summarize
            }
        }
    }

    let id = UUID()
    let session: URL
    let config: AppConfig
    let job: Job
    /// Receives the result of history jobs. Called exactly once: when the job
    /// finishes, or with "Cancelled" when it is removed from the queue.
    var completion: ((PipelineRunner.CLIResult) -> Void)?
}

// MARK: - Processing queue

/// Back-to-back meetings: a recording can start while earlier ones are still
/// being processed. Jobs queue up and run one at a time, oldest first.
/// On-device work waits while a recording is in progress so it doesn't
/// compete with the live call for CPU and the Neural Engine; cloud work,
/// which barely touches the Mac, carries on.
extension PipelineRunner {
    /// How often a deferred step re-checks whether the recording has ended.
    private static let recordingPollInterval: Duration = .seconds(1)

    /// Queue a job. Returns `false` (and queues nothing) when the same kind
    /// of job for the same session is already queued or running.
    @discardableResult
    func enqueueProcessing(_ item: QueuedSession) -> Bool {
        let kind = item.job.kind
        let active = [processingItem].compactMap { $0 } + processingQueue
        let duplicate = active.contains { $0.session == item.session && $0.job.kind == kind }
        guard !duplicate else {
            logger.info("duplicate job ignored session=\(item.session.lastPathComponent, privacy: .public)")
            return false
        }
        processingQueue.append(item)
        logger.info("queued session=\(item.session.lastPathComponent, privacy: .public) depth=\(self.processingQueue.count, privacy: .public)")
        if queueWorker == nil {
            queueWorker = Task { await drainQueue() }
        }
        return true
    }

    /// Queue a history job and wait for its result.
    func runQueued(_ session: URL, config: AppConfig, job: QueuedSession.Job) async -> CLIResult {
        await withCheckedContinuation { cont in
            let item = QueuedSession(session: session, config: config, job: job) { cont.resume(returning: $0) }
            if !enqueueProcessing(item) {
                cont.resume(returning: CLIResult(ok: false, error: "Already queued"))
            }
        }
    }

    /// 1-based position of `session` among the jobs waiting behind the one
    /// that is running, or `nil` when it isn't waiting.
    func queuePosition(of session: URL) -> Int? {
        processingQueue.firstIndex { $0.session == session }.map { $0 + 1 }
    }

    /// Drop every waiting job for `session`. The running job is not touched;
    /// cancel it with `cancelProcessing`.
    func removeFromQueue(_ session: URL) {
        let removed = processingQueue.filter { $0.session == session }
        processingQueue.removeAll { $0.session == session }
        for item in removed {
            appendSessionLog(session, "removed from the processing queue")
            item.completion?(CLIResult(ok: false, error: "Cancelled"))
        }
    }

    private func drainQueue() async {
        while !processingQueue.isEmpty {
            let item = processingQueue.removeFirst()
            processingItem = item
            let task = Task { await run(item) }
            processingItemTask = task
            let result = await task.value
            processingItemTask = nil
            processingItem = nil
            // A cancelled summary is swallowed as non-fatal, so nothing else
            // clears the flag before the next job starts.
            isCancelling = false
            item.completion?(result)
        }
        queueWorker = nil
    }

    private func run(_ item: QueuedSession) async -> CLIResult {
        switch item.job {
        case .recording(let summarize):
            await processSession(item.session, config: item.config, summarize: summarize)
            return CLIResult(ok: true, error: "")
        case let .transcribe(languageOverride, backendOverride):
            return await runTranscribeJob(
                item.session,
                config: item.config,
                languageOverride: languageOverride,
                backendOverride: backendOverride,
            )
        case let .summarize(profile, overrides):
            return await runSummarizeJob(item.session, config: item.config, profile: profile, overrides: overrides)
        }
    }

    /// Record the queue's phase and show it unless a recording, or a
    /// question about the recording that just ended, owns the UI.
    func setProcessingState(_ newState: AppState) {
        processingState = newState
        guard !state.isRecording, !isAwaitingRecordingAnswer else { return }
        state = newState
    }

    /// True while the queue is transcribing / summarizing.
    var isProcessingActive: Bool {
        queueWorker != nil
    }

    /// Suspend until no recording is in progress, when `condition` holds.
    /// Cancellation ends the wait early; the caller's next step observes it.
    func waitForRecordingToEnd(if condition: Bool, logger sessionLogger: SessionLogger? = nil) async {
        guard condition, state.isRecording else { return }
        sessionLogger?.log("waiting for the current recording to end before on-device processing")
        while state.isRecording, !Task.isCancelled {
            try? await Task.sleep(for: Self.recordingPollInterval)
        }
    }
}
