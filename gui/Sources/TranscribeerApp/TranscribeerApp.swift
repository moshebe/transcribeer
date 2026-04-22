import SwiftUI
import UserNotifications

/// Live state for a pending Zoom auto-record countdown.
///
/// Reference type so the owning view can identity-check the active countdown
/// inside the async timer task (user may cancel + new meeting detection may
/// start a fresh one before the old task observes cancellation).
@Observable
@MainActor
final class AutoRecordCountdown {
    var secondsRemaining: Int
    @ObservationIgnored var task: Task<Void, Never>?

    init(secondsRemaining: Int) {
        self.secondsRemaining = secondsRemaining
    }
}

@main
struct TranscribeerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var runner = PipelineRunner()
    @State private var zoomWatcher = ZoomWatcher()
    @State private var config = ConfigManager.load()
    @State private var autoRecordCountdown: AutoRecordCountdown?

    var body: some Scene {
        MenuBarExtra {
            menuContent
                .onChange(of: zoomWatcher.inMeeting) { _, inMeeting in
                    handleZoomChange(inMeeting: inMeeting)
                }
        } label: {
            MenuBarIcon(runner: runner)
                .task { onFirstAppear() }
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
        if let countdown = autoRecordCountdown {
            Text("⏱ Auto-recording in \(countdown.secondsRemaining)s")
            Button("⏹ Cancel auto-record") {
                cancelAutoRecordCountdown()
            }
            Divider()
        }

        switch runner.state {
        case .idle:
            if zoomWatcher.inMeeting && autoRecordCountdown == nil {
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
        appDelegate.onCancelAutoRecord = {
            Task { @MainActor in
                cancelAutoRecordCountdown()
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
            if config.zoomAutoRecord && !runner.state.isBusy && autoRecordCountdown == nil {
                scheduleAutoRecord()
            } else if !isRecording && autoRecordCountdown == nil {
                NotificationManager.sendZoomNotification()
            }
        } else {
            NotificationManager.cancelZoomNotification()
            // Meeting ended mid-countdown — abort the auto-start.
            if autoRecordCountdown != nil {
                cancelAutoRecordCountdown()
            }
            // Auto-stop if we auto-started this recording
            if isRecording && runner.zoomAutoStarted {
                runner.stopRecording()
            }
        }
    }

    private func startRecording(autoStarted: Bool) {
        NotificationManager.cancelZoomNotification()
        if !autoStarted {
            cancelAutoRecordCountdown()
        }
        runner.zoomAutoStarted = autoStarted
        runner.startRecording(config: config)

        if autoStarted {
            notifyZoomAutoRecord()
            prefillZoomTitle()
        }
    }

    /// Send a notification announcing auto-record has started.
    /// Briefly waits for the Zoom meeting title to populate before posting.
    private func notifyZoomAutoRecord() {
        Task { @MainActor in
            for _ in 0..<10 {
                if zoomWatcher.meetingTitle() != nil { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            NotificationManager.notifyZoomAutoRecordStarted(title: zoomWatcher.meetingTitle())
        }
    }

    // MARK: - Auto-record countdown

    private func scheduleAutoRecord() {
        let delay = max(0, config.zoomAutoRecordDelay)
        if delay == 0 {
            startRecording(autoStarted: true)
            return
        }

        let countdown = AutoRecordCountdown(secondsRemaining: delay)
        autoRecordCountdown = countdown

        let title = zoomWatcher.meetingTitle()
        NotificationManager.showZoomCountdown(secondsRemaining: delay, title: title)

        countdown.task = Task { @MainActor in
            var remaining = delay
            while remaining > 0 {
                autoRecordCountdown?.secondsRemaining = remaining
                NotificationManager.showZoomCountdown(
                    secondsRemaining: remaining,
                    title: zoomWatcher.meetingTitle() ?? title
                )
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return // cancelled
                }
                remaining -= 1
            }
            // Timer complete — only fire if still the active countdown.
            guard autoRecordCountdown === countdown else { return }
            autoRecordCountdown = nil
            NotificationManager.cancelZoomCountdown()
            guard zoomWatcher.inMeeting, !runner.state.isBusy else { return }
            startRecording(autoStarted: true)
        }
    }

    private func cancelAutoRecordCountdown() {
        autoRecordCountdown?.task?.cancel()
        autoRecordCountdown = nil
        NotificationManager.cancelZoomCountdown()
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
