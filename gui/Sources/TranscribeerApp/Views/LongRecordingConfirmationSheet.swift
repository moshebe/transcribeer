import SwiftUI

/// Sheet presented before summarization when a recording exceeds the configured
/// long-recording threshold (Track 4.5).
struct LongRecordingConfirmationSheet: View {
    let durationMinutes: Int
    let onConfirm: (Bool) -> Void // true = summarize, false = skip

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // MARK: Header
            VStack(alignment: .leading, spacing: 4) {
                Text("Long recording")
                    .font(.headline)
                Text("This is a \(durationMinutes)-minute recording. Summarizing may take a few minutes.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // MARK: Action buttons
            VStack(spacing: 10) {
                Button {
                    onConfirm(true)
                } label: {
                    HStack {
                        Image(systemName: "text.badge.checkmark")
                        Text("Summarize now")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)

                Button {
                    onConfirm(false)
                } label: {
                    HStack {
                        Image(systemName: "text.alignleft")
                        Text("Just save transcript")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}
