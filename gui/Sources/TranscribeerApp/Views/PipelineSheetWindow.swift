import SwiftUI

/// Content of the "pipeline-sheet" Window scene. Renders the appropriate
/// prompt sheet based on the current `PipelineRunner` state.
///
/// The window is opened automatically when the runner enters
/// `.awaitingPostRecordingChoice` or `.awaitingLongRecordingConfirmation`,
/// and closes itself once the user makes a choice (state leaves those values).
struct PipelineSheetWindow: View {
    let runner: PipelineRunner

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch runner.state {
            case .awaitingPostRecordingChoice:
                PostRecordingSheet(
                    sessionName: runner.postRecordingSessionName ?? "",
                    duration: runner.postRecordingDuration,
                    onChoice: { choice in
                        runner.resolvePostRecordingChoice(choice)
                        dismiss()
                    }
                )

            case .awaitingLongRecordingConfirmation:
                if let seconds = runner.pendingLongRecordingDuration {
                    LongRecordingConfirmationSheet(
                        durationMinutes: max(1, Int(seconds / 60)),
                        onConfirm: { shouldSummarize in
                            runner.confirmLongRecording(shouldSummarize)
                            dismiss()
                        }
                    )
                } else {
                    EmptyView()
                        .onAppear { dismiss() }
                }

            default:
                // State resolved while window was open — just close.
                EmptyView()
                    .onAppear { dismiss() }
            }
        }
        .onChange(of: runner.state) { _, newState in
            switch newState {
            case .awaitingPostRecordingChoice, .awaitingLongRecordingConfirmation:
                break
            default:
                dismiss()
            }
        }
    }
}
