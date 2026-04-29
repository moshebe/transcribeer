import AppKit
import SwiftUI
import TranscribeerCore
import UniformTypeIdentifiers

struct HistoryView: View {
    @Binding var config: AppConfig
    let runner: PipelineRunner

    @State private var sessions: [Session] = []
    @State private var selectedSessionID: String?
    @State private var detail: SessionDetail?
    @State private var searchText = ""
    @State private var profiles: [String] = ["default"]
    @State private var statusText = ""

    /// SwiftUI's canonical way to open the app's Settings scene (macOS 14+).
    /// The older NSApp.sendAction("showSettingsWindow:") path is flaky in
    /// menu-bar-extra-only apps because there's no first responder to route
    /// the selector through; this environment action talks to the Settings
    /// scene directly.
    @Environment(\.openSettings) private var openSettingsEnv

    var body: some View {
        VStack(spacing: 0) {
            controlBar
            Divider()
            NavigationSplitView {
                sidebar
            } detail: {
                detailPanel
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            refresh()
            profiles = PromptProfileManager.listProfiles()
            DockVisibility.windowDidAppear()
        }
        .onDisappear {
            DockVisibility.windowDidDisappear()
        }
        .onChange(of: runner.state) { _, newState in
            handleStateChange(newState)
        }
    }

    // MARK: - Control bar
    //
    // Surfaces the record/stop/cancel controls inside the window, so users
    // without the menubar icon visible (e.g. when other menu-bar extras push
    // ours behind the notch on MacBook Pros) still have a first-class way to
    // drive the pipeline. The menubar dropdown keeps working exactly as
    // before; this is an additive surface for the same `PipelineRunner`
    // state machine.

    private var controlBar: some View {
        HStack(spacing: 12) {
            stateIndicator
            Spacer()
            importButton
            settingsButton
            primaryActionButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    /// Tray-icon next to the primary action — lets users import an existing
    /// audio file (Voice Memos export, Zoom recording, WhatsApp .m4a, anything
    /// AVFoundation can decode) as a new session so they can transcribe it
    /// without re-recording.
    private var importButton: some View {
        Button {
            importAudioFile()
        } label: {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 16))
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .help("Import audio file…")
        .keyboardShortcut("i", modifiers: .command)
    }

    /// Gear icon next to the primary action — opens the Settings scene. Gives
    /// users a discoverable in-window entry point instead of relying on the
    /// macOS App menu or ⌘, (which aren't obvious if the menu bar extras are
    /// hidden behind the notch).
    private var settingsButton: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            openSettingsEnv()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 16))
        }
        .buttonStyle(.borderless)
        .controlSize(.large)
        .help("Settings (⌘,)")
        .keyboardShortcut(",", modifiers: .command)
    }

    // MARK: - Import

    /// File-picker flow: pick one or more audio files, copy each into a new
    /// session directory under `sessions_dir`, name the session from the
    /// original filename, and select the first imported session in the
    /// sidebar.
    private func importAudioFile() {
        let panel = NSOpenPanel()
        panel.title = "Import audio file(s)"
        panel.message = "Select one or more audio recordings to import as sessions."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie]

        // Default to wherever audio recordings most commonly live on this
        // Mac: the Voice Memos folder if we can actually read it, else the
        // Desktop (where exports and manual recordings land). Only a default;
        // user can navigate anywhere in the picker.
        panel.directoryURL = defaultImportDirectory()

        // Block until user picks. .OK = chose at least one file.
        guard panel.runModal() == .OK else { return }

        let urls = panel.urls
        guard !urls.isEmpty else { return }

        var firstImportedID: String?
        var imported = 0
        var failed: [String] = []

        for url in urls {
            do {
                let sessionURL = try importSessionFromFile(url: url)
                if firstImportedID == nil {
                    firstImportedID = sessionURL.path
                }
                imported += 1
            } catch {
                failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        refresh()
        if let firstImportedID {
            selectedSessionID = firstImportedID
            loadDetail(sessionID: firstImportedID)
        }

        if failed.isEmpty {
            statusText = imported == 1
                ? "Imported \"\(urls[0].lastPathComponent)\"."
                : "Imported \(imported) files."
        } else {
            statusText = "Imported \(imported); \(failed.count) failed: \(failed.joined(separator: "; "))"
        }
    }

    /// Create a new session directory for `url` and copy the file in as
    /// `audio.<ext>` (normalising m4a/wav names so the rest of the pipeline
    /// finds it via `SessionManager.audioURL(in:)`). Preserves the original
    /// filename (minus extension) as the session's display name via meta.json.
    private func importSessionFromFile(url: URL) throws -> URL {
        let sessionDir = SessionManager.newSession(sessionsDir: config.expandedSessionsDir)
        let ext = url.pathExtension.lowercased()
        // SessionManager.audioURL looks for audio.m4a then audio.wav. For any
        // other audio type, fall back to .m4a so AVFoundation still picks it
        // up (it doesn't need the extension to match the container).
        let targetName = (ext == "m4a" || ext == "wav") ? "audio.\(ext)" : "audio.m4a"
        let targetURL = sessionDir.appendingPathComponent(targetName)
        try FileManager.default.copyItem(at: url, to: targetURL)

        // Persist the original filename as the display name.
        let baseName = url.deletingPathExtension().lastPathComponent
        if !baseName.isEmpty {
            SessionManager.setName(sessionDir, baseName)
        }
        return sessionDir
    }

    /// Pick a sensible default starting folder for the import panel. Prefers
    /// a Voice Memos container we can actually read; falls back to Desktop,
    /// then Downloads, then the user's home directory. Readability is checked
    /// via `contentsOfDirectory`, not just existence — the Voice Memos folder
    /// exists on every Mac but is TCC-gated on modern macOS and `fileExists`
    /// wrongly reports it as usable.
    private func defaultImportDirectory() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [URL] = [
            home.appendingPathComponent(
                "Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings",
            ),
            home.appendingPathComponent(
                "Library/Containers/com.apple.VoiceMemos/Data/Library/Recordings",
            ),
            home.appendingPathComponent(
                "Library/Application Support/com.apple.voicememos/Recordings",
            ),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Downloads"),
            home,
        ]
        let fm = FileManager.default
        return candidates.first { (try? fm.contentsOfDirectory(atPath: $0.path)) != nil }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        switch runner.state {
        case .idle:
            Label("Ready to record", systemImage: "mic")
                .foregroundStyle(.secondary)
        case .recording(let startTime):
            TimelineView(.periodic(from: startTime, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(startTime))
                Label(
                    "Recording  \(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))",
                    systemImage: "record.circle.fill",
                )
                .foregroundStyle(.red)
            }
        case .transcribing:
            if let pct = runner.transcriptionProgress {
                Label("Transcribing  \(Int(pct * 100))%", systemImage: "waveform")
            } else {
                Label("Transcribing…", systemImage: "waveform")
            }
        case .summarizing:
            Label("Summarizing…", systemImage: "sparkles")
        case .done:
            Label("Done", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .lineLimit(1)
                .help(msg)
        }
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        switch runner.state {
        case .idle, .done, .error:
            Button {
                runner.startRecording(config: config)
            } label: {
                Label("Record", systemImage: "record.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .keyboardShortcut("r", modifiers: .command)
            .help("Start recording (⌘R)")
        case .recording:
            Button {
                runner.stopRecording()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(".", modifiers: .command)
            .help("Stop recording (⌘.)")
        case .transcribing, .summarizing:
            Button {
                runner.cancelProcessing()
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(".", modifiers: .command)
            .help("Cancel (⌘.)")
        }
    }

    private func handleStateChange(_ newState: AppState) {
        // Whenever the pipeline transitions — recording starts, recording
        // ends, transcription finishes — refresh the sidebar list so newly
        // produced sessions and artifacts show up immediately.
        refresh()

        // Auto-select the session the runner is actively working on so the
        // user sees its detail without having to click the new row manually.
        if let current = runner.currentSession, selectedSessionID != current.path {
            selectedSessionID = current.path
            loadDetail(sessionID: current.path)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(filteredSessions, selection: $selectedSessionID) { session in
            SessionRow(session: session)
        }
        .searchable(text: $searchText, prompt: "Search sessions…")
        .navigationTitle("Transcribeer")
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        .onChange(of: selectedSessionID) { _, newID in
            loadDetail(sessionID: newID)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPanel: some View {
        if let session = selectedSession, let detail {
            SessionDetailView(
                session: session,
                detail: detail,
                profiles: profiles,
                runner: runner,
                config: config,
                statusText: $statusText,
                onRename: { newName in
                    SessionManager.setName(session.path, newName)
                    refresh()
                },
                onSaveNotes: { newNotes in
                    SessionManager.setNotes(session.path, newNotes)
                },
                onTranscribe: { languageOverride in
                    statusText = ""
                    Task {
                        let result = await runner.transcribeSession(
                            session.path,
                            config: config,
                            languageOverride: languageOverride
                        )
                        statusText = result.ok
                            ? "Transcription done."
                            : "Transcription failed: \(result.error)"
                        loadDetail(sessionID: selectedSessionID)
                    }
                },
                onSummarize: { request in
                    statusText = "Summarizing…"
                    Task {
                        let result = await runner.summarizeSession(
                            session.path,
                            config: config,
                            profile: request.profile,
                            overrides: .init(
                                backend: request.backend,
                                model: request.model,
                                focus: request.focus
                            )
                        )
                        statusText = result.ok
                            ? "Summary done."
                            : "Summarization failed: \(result.error)"
                        loadDetail(sessionID: selectedSessionID)
                    }
                },
                onOpenDir: {
                    NSWorkspace.shared.open(session.path)
                },
                onDelete: {
                    deleteSession(session)
                }
            )
        } else {
            ContentUnavailableView(
                "Select a Recording",
                systemImage: "waveform",
                description: Text("Choose a session from the sidebar to view details.")
            )
        }
    }

    // MARK: - Helpers

    private var filteredSessions: [Session] {
        if searchText.isEmpty { return sessions }
        let query = searchText.lowercased()
        return sessions.filter { $0.name.lowercased().contains(query) }
    }

    private var selectedSession: Session? {
        sessions.first { $0.id == selectedSessionID }
    }

    private func refresh() {
        sessions = SessionManager.listSessions(sessionsDir: config.expandedSessionsDir)
        if selectedSessionID == nil, let first = sessions.first {
            selectedSessionID = first.id
        }
    }

    private func loadDetail(sessionID: String?) {
        guard let sessionID else {
            detail = nil
            return
        }
        detail = SessionManager.sessionDetail(URL(fileURLWithPath: sessionID))
    }

    private func deleteSession(_ session: Session) {
        guard SessionManager.deleteSession(session.path) else {
            statusText = "Failed to delete session."
            return
        }
        statusText = "Session moved to Trash."
        if selectedSessionID == session.id {
            selectedSessionID = nil
            detail = nil
        }
        refresh()
    }
}

// MARK: - Session row

private struct SessionRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(session.name)
                    .font(.system(size: 13, weight: session.isUntitled ? .regular : .semibold))
                    .foregroundStyle(session.isUntitled ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                artifactIcons
            }

            HStack(spacing: 4) {
                Text(session.formattedDate)
                if !session.duration.isEmpty && session.duration != "—" {
                    Text("·")
                    Text(session.duration)
                }
                if let badge = languageBadge {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.5)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if !session.snippet.isEmpty {
                Text(session.snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    /// Small glyph trio on the right of each row showing which artifacts
    /// exist for the session: audio, transcript, summary. A dimmed glyph
    /// means the artifact is missing — so users can see at a glance whether
    /// a session still needs transcribing or summarizing.
    @ViewBuilder
    private var artifactIcons: some View {
        HStack(spacing: 4) {
            artifactIcon(
                systemName: "waveform",
                present: session.hasAudio,
                help: session.hasAudio ? "Audio recorded" : "No audio"
            )
            artifactIcon(
                systemName: "text.alignleft",
                present: session.hasTranscript,
                help: session.hasTranscript ? "Transcript available" : "Not transcribed"
            )
            artifactIcon(
                systemName: "sparkles",
                present: session.hasSummary,
                help: session.hasSummary ? "Summary available" : "Not summarized"
            )
        }
    }

    private func artifactIcon(systemName: String, present: Bool, help: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(present ? Color.accentColor : Color.secondary.opacity(0.35))
            .help(help)
            .accessibilityLabel(help)
    }

    private var languageBadge: String? {
        session.language.flatMap { TranscriptionLanguage.from($0).badgeText }
    }
}
