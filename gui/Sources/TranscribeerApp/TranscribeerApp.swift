import SwiftUI
import UserNotifications

@main
struct TranscribeerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var runner = PipelineRunner()
    @State private var zoomWatcher = ZoomWatcher()
    @State private var config = ConfigManager.load()

    var body: some Scene {
        MenuBarExtra {
            menuContent
                .onAppear { onFirstAppear() }
                .onChange(of: zoomWatcher.inMeeting) { _, inMeeting in
                    handleZoomChange(inMeeting: inMeeting)
                }
        } label: {
            MenuBarIcon(state: runner.state)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(config: $config)
        }

        Window("Recording History", id: "history") {
            HistoryView(config: $config, runner: runner)
        }
        .defaultSize(width: 900, height: 600)
    }

    // MARK: - Menu

    @ViewBuilder
    private var menuContent: some View {
        switch runner.state {
        case .idle:
            if zoomWatcher.inMeeting {
                Button("⏺ Record Zoom") {
                    startRecording(autoStarted: false)
                }
                Divider()
            }
            Button("Start Recording") {
                startRecording(autoStarted: false)
            }

        case .recording(let startTime):
            let elapsed = elapsedString(from: startTime)
            Text("⏺ Recording  \(elapsed)")
            Button("⏹ Stop Recording") {
                runner.stopRecording()
            }

        case .transcribing:
            if let pct = runner.transcriptionProgress {
                Text("📝 Transcribing… \(Int(pct * 100))%")
            } else {
                Text("📝 Transcribing…")
            }
            Button("⏹ Stop") {
                runner.cancelProcessing()
            }

        case .summarizing:
            Text("🤔 Summarizing…")
            Button("⏹ Stop") {
                runner.cancelProcessing()
            }

        case .done(let path):
            Text("✓ Done")
            Button("📁 Open Session") {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            Divider()
            Button("Start Recording") {
                startRecording(autoStarted: false)
            }

        case .error(let msg):
            Text("⚠ \(msg)")
            Divider()
            Button("Start Recording") {
                startRecording(autoStarted: false)
            }
        }

        Divider()

        Button("History…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "history")
        }
        SettingsLink {
            Text("Settings…")
        }

        Divider()

        Button("Quit") { NSApp.terminate(nil) }
    }

    @Environment(\.openWindow) private var openWindow

    // MARK: - Lifecycle

    private func onFirstAppear() {
        zoomWatcher.startPolling()

        // Wire notification "Start Recording" action → startRecording
        appDelegate.onRecord = { [runner] in
            Task { @MainActor in
                guard !runner.state.isBusy else { return }
                NotificationManager.cancelZoomNotification()
                runner.startRecording(config: ConfigManager.load())
            }
        }

        // Check if Zoom is already running at launch
        if zoomWatcher.inMeeting {
            handleZoomChange(inMeeting: true)
        }
    }

    // MARK: - Zoom integration

    private func handleZoomChange(inMeeting: Bool) {
        let isRecording = runner.state.isRecording

        if inMeeting {
            if config.zoomAutoRecord && !runner.state.isBusy {
                startRecording(autoStarted: true)
                prefillZoomTitle()
            } else if !isRecording {
                NotificationManager.sendZoomNotification()
            }
        } else {
            NotificationManager.cancelZoomNotification()
            // Auto-stop if we auto-started this recording
            if isRecording && runner.zoomAutoStarted {
                runner.stopRecording()
            }
        }
    }

    private func startRecording(autoStarted: Bool) {
        NotificationManager.cancelZoomNotification()
        runner.zoomAutoStarted = autoStarted
        runner.startRecording(config: config)

        if autoStarted {
            prefillZoomTitle()
        }
    }

    /// After a short delay, read the Zoom meeting title and set it as the session name.
    private func prefillZoomTitle() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard let session = runner.currentSession else { return }
            // Don't overwrite if already named
            let meta = SessionManager.readMeta(session)
            if let name = meta["name"] as? String, !name.isEmpty { return }

            if let title = zoomWatcher.meetingTitle() {
                SessionManager.setName(session, title)
            }
        }
    }

    // MARK: - Helpers

    private func elapsedString(from start: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(start))
        let m = elapsed / 60
        let s = elapsed % 60
        return String(format: "%02d:%02d", m, s)
    }
}
