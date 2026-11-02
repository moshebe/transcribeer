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
}
