import SwiftUI

/// Menu bar icon that overlays a red dot on the mic while recording.
///
/// When the running bundle identifier ends in `.dev` (i.e. this is a
/// locally-built dev variant running alongside a main/prod install), a small
/// orange "D" is overlaid so the two menubar icons can be told apart at a
/// glance. The check is compiled in unconditionally but is a no-op for a
/// normally-signed production bundle whose id has no `.dev` suffix.
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
            if Self.isDevBuild {
                Text("D")
                    .font(.system(size: 8, weight: .heavy, design: .rounded))
                    .foregroundStyle(.orange)
                    .offset(x: 5, y: 6)
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

    private static let isDevBuild: Bool = {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
    }()
}
