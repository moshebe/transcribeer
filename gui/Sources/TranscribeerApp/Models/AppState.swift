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
        case .recording, .transcribing, .summarizing: true
        default: false
        }
    }

    var statusText: String {
        switch self {
        case .idle: ""
        case .recording(let start): Self.recordingText(from: start)
        case .transcribing: "📝 Transcribing…"
        case .summarizing: "🤔 Summarizing…"
        case .done: "✓ Done"
        case .error(let msg): "⚠ \(msg)"
        }
    }

    private static func recordingText(from start: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(start))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "⏺ Recording  %02d:%02d", minutes, seconds)
    }
}
