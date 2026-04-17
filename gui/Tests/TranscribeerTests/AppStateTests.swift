import Foundation
import Testing
@testable import TranscribeerApp

struct AppStateTests {
    // MARK: - isRecording

    @Test("isRecording is true only for .recording state",
          arguments: [
              (AppState.idle, false),
              (.recording(startTime: .now), true),
              (.transcribing, false),
              (.summarizing, false),
              (.done(sessionPath: "/tmp"), false),
              (.error("fail"), false),
          ])
    func isRecording(state: AppState, expected: Bool) {
        #expect(state.isRecording == expected)
    }

    // MARK: - isBusy

    @Test("isBusy is true for recording, transcribing, and summarizing",
          arguments: [
              (AppState.idle, false),
              (.recording(startTime: .now), true),
              (.transcribing, true),
              (.summarizing, true),
              (.done(sessionPath: "/tmp"), false),
              (.error("fail"), false),
          ])
    func isBusy(state: AppState, expected: Bool) {
        #expect(state.isBusy == expected)
    }

    // MARK: - statusText

    @Test("Idle state has empty status text")
    func idleStatusText() {
        #expect(AppState.idle.statusText.isEmpty)
    }

    @Test("Transcribing shows pencil emoji")
    func transcribingStatusText() {
        #expect(AppState.transcribing.statusText == "📝 Transcribing…")
    }

    @Test("Summarizing shows thinking emoji")
    func summarizingStatusText() {
        #expect(AppState.summarizing.statusText == "🤔 Summarizing…")
    }

    @Test("Done shows checkmark")
    func doneStatusText() {
        #expect(AppState.done(sessionPath: "/tmp").statusText == "✓ Done")
    }

    @Test("Error includes the message")
    func errorStatusText() {
        let msg = "Something went wrong"
        #expect(AppState.error(msg).statusText == "⚠ \(msg)")
    }

    @Test("Recording status includes elapsed time format")
    func recordingStatusFormat() {
        let past = Date().addingTimeInterval(-125) // 2m 5s ago
        let text = AppState.recording(startTime: past).statusText
        #expect(text.hasPrefix("⏺ Recording"))
        #expect(text.contains("02:0"))
    }
}
