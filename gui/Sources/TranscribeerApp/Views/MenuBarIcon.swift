import SwiftUI

/// Menu bar icon that overlays a red dot on the mic while recording.
struct MenuBarIcon: View {
    let state: AppState

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: iconName)
            if state.isRecording {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
                    .offset(x: 2, y: -1)
            }
        }
    }

    private var iconName: String {
        switch state {
        case .idle, .recording: "mic"
        case .transcribing, .summarizing: "ellipsis.circle"
        case .done: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }
}
