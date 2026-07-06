import TranscribeerCore
import Foundation

/// What the user chose to do after stopping a recording (Track 4.3).
enum PostRecordingChoice {
    case transcribeAndSummarize
    case transcribeOnly
    case saveOnly
    case discard
}

/// Single source of truth for the app's pipeline state.
enum AppState: Equatable {
    case idle
    case recording(startTime: Date)
    /// Waiting for the user to choose what to do after a recording stopped (Track 4.3).
    case awaitingPostRecordingChoice
    case transcribing
    /// Waiting for the user to confirm summarization of a long recording (Track 4.5).
    case awaitingLongRecordingConfirmation
    case summarizing
    case done(sessionPath: String)
    case error(String)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .recording, .transcribing, .summarizing: return true
        default: return false
        }
    }
}
