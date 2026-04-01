import SwiftUI
import AppKit

// AppState is defined in TranscribeeRunner.swift

// MARK: - MenuBarView

struct MenuBarView: View {
    @EnvironmentObject var runner: TranscribeeRunner
    @EnvironmentObject var watcher: AppWatcher

    var body: some View {
        switch runner.state {
        case .idle:
            if let meetingApp = watcher.activeMeetingApp {
                Button("▶ \(meetingApp) detected — Start Recording") { runner.start() }
                Divider()
            }
            Button("Start Recording") { runner.start() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }

        case .recording:
            Button("⏺ Recording  —  Click to stop") { runner.stop() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }

        case .transcribing:
            Text("⏳ Transcribing…")
                .foregroundColor(.secondary)
            Divider()
            Button("Quit") { NSApp.terminate(nil) }

        case .summarizing:
            Text("⏳ Summarizing…")
                .foregroundColor(.secondary)
            Divider()
            Button("Quit") { NSApp.terminate(nil) }

        case .done(let path):
            Button("✓ Open session") {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            Divider()
            Button("Start Recording") { runner.start() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }

        case .error(let msg):
            Text("⚠ \(msg)")
                .foregroundColor(.red)
            Divider()
            Button("Start Recording") { runner.start() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}
