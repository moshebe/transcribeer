import Foundation
import Testing
@testable import TranscribeerApp

/// Back-to-back meetings: processing an earlier recording must never take the
/// UI (or the Record button) away from a recording in progress.
@MainActor
struct PipelineQueueTests {
    private let recording = AppState.recording(startTime: Date(timeIntervalSince1970: 0))

    private func tempLogger() -> SessionLogger {
        SessionLogger(logPath: FileManager.default.temporaryDirectory
            .appendingPathComponent("run-\(UUID().uuidString).log"))
    }

    @Test("Processing phases don't replace a recording in progress", arguments: [
        AppState.transcribing,
        .summarizing,
        .awaitingPostRecordingChoice,
        .done(sessionPath: "/tmp/earlier"),
        .error("Transcription failed"),
    ])
    func processingStateDoesNotOverrideRecording(phase: AppState) {
        let runner = PipelineRunner()
        runner.state = recording

        runner.setProcessingState(phase)

        #expect(runner.state == recording)
        #expect(runner.processingState == phase)
    }

    @Test("Processing phases show when no recording is in progress")
    func processingStateShowsWhenIdle() {
        let runner = PipelineRunner()

        runner.setProcessingState(.summarizing)

        #expect(runner.state == .summarizing)
    }

    @Test("A new recording can start while an earlier one is processing")
    func recordingIsNotBlockedByProcessing() {
        let runner = PipelineRunner()
        runner.setProcessingState(.transcribing)

        // `startRecording` only refuses a second concurrent recording.
        #expect(!runner.state.isRecording)
        #expect(runner.state.isBusy)
    }

    @Test("On-device work waits for the recording to end")
    func waitsForRecordingToEnd() async {
        let runner = PipelineRunner()
        runner.state = recording

        let waiter = Task { @MainActor in
            await runner.waitForRecordingToEnd(if: true, logger: tempLogger())
            return runner.state
        }
        try? await Task.sleep(for: .milliseconds(200))
        runner.state = .idle

        #expect(await waiter.value == .idle)
    }

    @Test("Cloud work doesn't wait for the recording")
    func cloudWorkDoesNotWait() async {
        let runner = PipelineRunner()
        runner.state = recording

        await runner.waitForRecordingToEnd(if: false, logger: tempLogger())

        #expect(runner.state == recording)
    }

    @Test("Cancelling a deferred step ends its wait")
    func cancellationEndsWait() async {
        let runner = PipelineRunner()
        runner.state = recording

        let waiter = Task { @MainActor in
            await runner.waitForRecordingToEnd(if: true, logger: tempLogger())
        }
        waiter.cancel()
        await waiter.value

        #expect(runner.state == recording)
    }

    // MARK: - Recording end

    @Test("Ending capture clears the recording state")
    func releaseClearsRecording() {
        let runner = PipelineRunner()
        runner.state = recording

        runner.releaseRecordingState()

        #expect(runner.state == .idle)
    }

    @Test("Ending capture lets deferred on-device work continue")
    func releaseEndsWait() async {
        let runner = PipelineRunner()
        runner.state = recording

        let waiter = Task { @MainActor in
            await runner.waitForRecordingToEnd(if: true, logger: tempLogger())
            return runner.state.isRecording
        }
        try? await Task.sleep(for: .milliseconds(200))
        runner.releaseRecordingState()

        #expect(await waiter.value == false)
    }

    @Test("Releasing leaves a non-recording state alone")
    func releaseKeepsOtherStates() {
        let runner = PipelineRunner()
        runner.state = .awaitingPostRecordingChoice

        runner.releaseRecordingState()

        #expect(runner.state == .awaitingPostRecordingChoice)
    }

    // MARK: - Queue contents

    private func job(_ session: URL, _ job: QueuedSession.Job, results: Box) -> QueuedSession {
        QueuedSession(session: session, config: AppConfig(), job: job) { results.values.append($0) }
    }

    /// Collects job results; the queue calls completions on the main actor.
    private final class Box {
        var values: [PipelineRunner.CLIResult] = []
    }

    @Test("A duplicate job for the same session and kind is rejected")
    func duplicateJobRejected() async {
        let runner = PipelineRunner()
        let results = Box()
        let session = URL(fileURLWithPath: "/tmp/queued-a")
        let transcribe = QueuedSession.Job.transcribe(languageOverride: nil, backendOverride: nil)

        #expect(runner.enqueueProcessing(job(session, transcribe, results: results)))
        #expect(!runner.enqueueProcessing(job(session, transcribe, results: results)))
        #expect(runner.enqueueProcessing(job(session, .summarize(profile: nil, overrides: .init()), results: results)))
        #expect(runner.queuedSessionCount == 2)

        runner.removeFromQueue(session)
        await runner.queueWorker?.value
    }

    @Test("Waiting jobs report their position and can be removed")
    func removeFromQueue() async {
        let runner = PipelineRunner()
        let results = Box()
        let first = URL(fileURLWithPath: "/tmp/queued-1")
        let second = URL(fileURLWithPath: "/tmp/queued-2")
        let transcribe = QueuedSession.Job.transcribe(languageOverride: nil, backendOverride: nil)
        runner.enqueueProcessing(job(first, transcribe, results: results))
        runner.enqueueProcessing(job(second, transcribe, results: results))

        #expect(runner.queuePosition(of: first) == 1)
        #expect(runner.queuePosition(of: second) == 2)

        runner.removeFromQueue(first)

        #expect(runner.queuePosition(of: first) == nil)
        #expect(runner.queuePosition(of: second) == 1)
        #expect(results.values.map(\.error) == ["Cancelled"])

        runner.removeFromQueue(second)
        await runner.queueWorker?.value
        #expect(runner.queueWorker == nil)
    }
}
