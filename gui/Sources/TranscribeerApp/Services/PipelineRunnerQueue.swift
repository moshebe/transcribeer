import Foundation
import os.log

private let logger = Logger(subsystem: "com.transcribeer", category: "pipeline-queue")

/// A finished recording waiting for transcription / summarization, with the
/// config it was recorded under.
struct QueuedSession {
    let session: URL
    let config: AppConfig
}

// MARK: - Processing queue

/// Back-to-back meetings: a recording can start while earlier ones are still
/// being processed. Finished recordings queue up and are processed one at a
/// time, oldest first. On-device work waits while a recording is in progress
/// so it doesn't compete with the live call for CPU and the Neural Engine;
/// cloud work, which barely touches the Mac, carries on.
extension PipelineRunner {
    /// How often a deferred step re-checks whether the recording has ended.
    private static let recordingPollInterval: Duration = .seconds(1)

    func enqueueProcessing(_ item: QueuedSession) {
        processingQueue.append(item)
        logger.info("queued session=\(item.session.lastPathComponent, privacy: .public) depth=\(self.processingQueue.count, privacy: .public)")
        guard queueWorker == nil else { return }
        queueWorker = Task { await drainQueue() }
    }

    private func drainQueue() async {
        while !processingQueue.isEmpty {
            let item = processingQueue.removeFirst()
            let task = Task { await processSession(item.session, config: item.config) }
            processingItemTask = task
            await task.value
            processingItemTask = nil
            // A cancelled summary is swallowed as non-fatal, so nothing else
            // clears the flag before the next session starts.
            isCancelling = false
        }
        queueWorker = nil
    }

    /// Record the queue's phase and show it unless a recording owns the UI.
    func setProcessingState(_ newState: AppState) {
        processingState = newState
        guard !state.isRecording else { return }
        state = newState
    }

    /// True while the queue or a history re-run is transcribing / summarizing.
    var isProcessingActive: Bool {
        queueWorker != nil || transcribingSession != nil || summarizingSession != nil
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
