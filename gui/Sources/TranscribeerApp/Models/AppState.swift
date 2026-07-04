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

    var menuBarIcon: String {
        switch self {
        case .idle: return "mic"
        case .recording: return "record.circle.fill"
        case .transcribing, .summarizing: return "ellipsis.circle"
        case .awaitingPostRecordingChoice, .awaitingLongRecordingConfirmation:
            return "questionmark.circle"
        case .done: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    var statusText: String {
        switch self {
        case .idle: return ""
        case .recording(let start): return Self.recordingText(from: start)
        case .awaitingPostRecordingChoice: return "⏸ Recording saved — choose action"
        case .transcribing: return "📝 Transcribing…"
        case .awaitingLongRecordingConfirmation: return "⏸ Long recording — confirm"
        case .summarizing: return "🤔 Summarizing…"
        case .done: return "✓ Done"
        case .error(let msg): return "⚠ \(msg)"
        }
    }

    private static func recordingText(from start: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(start))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "⏺ Recording  %02d:%02d", minutes, seconds)
    }
}
