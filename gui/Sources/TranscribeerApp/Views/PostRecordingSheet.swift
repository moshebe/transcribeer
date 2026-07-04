import SwiftUI

/// Sheet presented after a recording stops when `config.promptOnStop` is true.
/// Lets the user choose what to do with the captured audio before the pipeline proceeds.
struct PostRecordingSheet: View {
    let sessionName: String
    let duration: TimeInterval
    let onChoice: (PostRecordingChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // MARK: Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Recording saved")
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // MARK: Action buttons
            VStack(spacing: 10) {
                actionButton(
                    title: "Transcribe & Summarize",
                    description: "Run the full pipeline (transcription + AI summary).",
                    icon: "text.badge.checkmark",
                    tint: .accentColor
                ) {
                    onChoice(.transcribeAndSummarize)
                }

                actionButton(
                    title: "Transcribe Only",
                    description: "Produce a transcript without an AI summary.",
                    icon: "waveform",
                    tint: .blue
                ) {
                    onChoice(.transcribeOnly)
                }

                actionButton(
                    title: "Just Save",
                    description: "Keep the audio file and transcribe later.",
                    icon: "square.and.arrow.down",
                    tint: .secondary
                ) {
                    onChoice(.saveOnly)
                }

                Divider()

                actionButton(
                    title: "Discard Recording",
                    description: "Delete the audio file permanently.",
                    icon: "trash",
                    tint: .red
                ) {
                    onChoice(.discard)
                }
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    // MARK: - Helpers

    private var headerSubtitle: String {
        let name = sessionName.isEmpty ? "Unnamed" : sessionName
        if duration > 0 {
            return "\(name) · \(Self.formatDuration(duration))"
        }
        return name
    }

    private func actionButton(
        title: String,
        description: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
