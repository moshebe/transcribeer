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
}
