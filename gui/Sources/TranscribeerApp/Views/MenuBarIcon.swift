import SwiftUI

/// Menu bar icon that overlays a red dot on the mic while recording.
///
/// `MenuBarExtra(style: .menu)` does not re-render its label when an
/// `@Observable` model's properties change — neither reading in the Scene body
/// nor reading in this view's body reliably triggers a refresh. To work around
/// the bug we mirror the runner's state into local `@State` via a polling task
/// started on the label (`.task` runs as long as the label exists). Local
/// `@State` mutations *do* refresh the menu-bar icon.
struct MenuBarIcon: View {
    let runner: PipelineRunner
    @State private var displayState: AppState = .idle

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: iconName(for: displayState))
            if displayState.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                    .offset(x: 2, y: -1)
            }
        }
        .task(id: ObjectIdentifier(runner)) {
            while !Task.isCancelled {
                let current = runner.state
                if current != displayState {
                    displayState = current
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func iconName(for state: AppState) -> String {
        switch state {
        case .idle, .recording: "mic"
        case .transcribing, .summarizing: "ellipsis.circle"
        case .done: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }
}
