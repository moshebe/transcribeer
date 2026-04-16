import TranscribeerCore
import Foundation

/// Single source of truth for the app's pipeline state.
enum AppState: Equatable {
    case idle
    case recording(startTime: Date)
    case transcribing
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
        case .done: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    var statusText: String {
        switch self {
        case .idle: return ""
        case .recording(let start):
            let elapsed = Int(Date().timeIntervalSince(start))
            let m = elapsed / 60
            let s = elapsed % 60
            return String(format: "⏺ Recording  %02d:%02d", m, s)
        case .transcribing: return "📝 Transcribing…"
        case .summarizing: return "🤔 Summarizing…"
        case .done: return "✓ Done"
        case .error(let msg): return "⚠ \(msg)"
        }
    }
}
