import AppKit
import SwiftUI
import TranscribeerCore
import UniformTypeIdentifiers

// Existing coordinator view owns history selection, detail, import, and pipeline bindings;
// splitting it safely is a separate refactor from this crash fix.
// swiftlint:disable:next type_body_length
struct HistoryView: View {
    @Binding var config: AppConfig
    let runner: PipelineRunner

    @State private var sessions: [Session] = []
    @State private var selectedSessionIDs: Set<String> = []
    @State private var detail: SessionDetail?
    @State private var searchText = ""
    @State private var profiles: [String] = ["default"]
    @State private var statusText = ""
    /// Sessions queued for confirmation — either a right-clicked row or the
    /// entire selection when the user hits Delete with multiple rows selected.
    /// Drives the confirmation dialog so nothing is deleted in a single click.
    @State private var sessionsPendingDeletion: [Session] = []
    /// Tracks the last session whose detail was actually read from disk so
    /// the `selectedSessionIDs` observer can skip reloads when the effective
    /// single-selection hasn't changed.
    @State private var lastLoadedDetailID: String?
    /// Cached availability for transcription backends. Drives the disabled
    /// state of cloud backends in the sidebar's right-click Transcribe
    /// submenu so users see *why* OpenAI/Gemini are greyed out (no API key)
    /// without having to open Settings first. Refreshed on appear and
    /// whenever the default backend changes in config.
    @State private var transcriptionAvailability = TranscriptionBackendAvailability.localOnly

    /// Single selection helper — `nil` when zero or multiple rows are selected.
    /// Used to decide whether to render the detail pane or a multi-select
    /// placeholder.
    private var selectedSessionID: String? {
        selectedSessionIDs.count == 1 ? selectedSessionIDs.first : nil
    }

    /// SwiftUI's canonical way to open the app's Settings scene (macOS 14+).
    /// The older NSApp.sendAction("showSettingsWindow:") path is flaky in
    /// menu-bar-extra-only apps because there's no first responder to route
    /// the selector through; this environment action talks to the Settings
    /// scene directly.
    @Environment(\.openSettings) private var openSettingsEnv

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                accessibilityBanner
                controlBar
                Divider()
                detailPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            refresh()
            profiles = PromptProfileManager.listProfiles()
            DockVisibility.windowDidAppear()
        }
        .task(id: config.transcriptionBackend) { await refreshTranscriptionAvailability() }
        .onDisappear {
            DockVisibility.windowDidDisappear()
        }
        .onChange(of: runner.state) { _, newState in
            handleStateChange(newState)
        }
        // When a pipeline run (record → transcribe → summarize, or a
        // re-transcribe / re-summarize from this view) finishes for the
        // currently-selected session, reload its detail from disk so the
        // transcript and summary tabs pick up the freshly-written content
        // without waiting on a Task continuation. Closes a race where
        // `transcribingSession` (or `summarizingSession`) flips to nil a
        // render-tick before the Task that launched the run gets to call
        // `loadDetail`, leaving the view showing the pre-run text until
        // the next user action. See tr-9d76.
        .onChange(of: runner.transcribingSession) { _, newValue in
            reloadOnPipelineFinish(newValue: newValue)
        }
        .onChange(of: runner.summarizingSession) { _, newValue in
            reloadOnPipelineFinish(newValue: newValue)
        }
        .onChange(of: selectedSessionIDs) { _, _ in
            reloadForSelectionChange()
        }
        // Refresh the profile dropdown whenever Settings adds, renames, or
        // deletes a profile. Without this the dropdown is stuck on whatever
        // was on disk when the window first opened.
        .onReceive(
            NotificationCenter.default.publisher(for: PromptProfileManager.didChangeNotification)
        ) { _ in
            profiles = PromptProfileManager.listProfiles()
        }
    }

    /// Shared handler for the transcribing/summarizing-session observers.
    /// Runs the on-disk reload only when the session just transitioned to
    /// `nil` (the pipeline finished) for the currently selected row.
    private func reloadOnPipelineFinish(newValue: URL?) {
        guard newValue == nil, let id = selectedSessionID else { return }
        loadDetail(sessionID: id)
        refresh()
    }

    /// Reload detail for selection changes. Skips the disk read when the
    /// same session is still selected (sidebar state can churn without the
    /// active row actually changing — e.g. a transient multi-select that
    /// collapses back to the original single row).
    private func reloadForSelectionChange() {
        let current = selectedSessionID
        guard current != lastLoadedDetailID else { return }
        loadDetail(sessionID: current)
    }

    // MARK: - Control bar
    //
    // Surfaces the record/stop/cancel controls inside the window, so users
    // without the menubar icon visible (e.g. when other menu-bar extras push
    // ours behind the notch on MacBook Pros) still have a first-class way to
    // drive the pipeline. The menubar dropdown keeps working exactly as
    // before; this is an additive surface for the same `PipelineRunner`
    // state machine.

    @ViewBuilder
    private var accessibilityBanner: some View {
        if config.zoomEnricherEnabled, !AccessibilityGuard.isTrusted {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility permission not granted")
                        .font(.headline)
                    Text("Zoom meeting titles and participants won't be captured until Transcribeer "
                        + "is enabled in System Settings → Privacy & Security → Accessibility.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Open Settings") {
                    AccessibilityGuard.prompt()
                    AccessibilityGuard.openSystemSettings()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.orange.opacity(0.4)), alignment: .bottom)
        }
    }

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
        .accessibilityLabel("Import audio file")
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
        .accessibilityLabel("Settings")
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
            selectedSessionIDs = [firstImportedID]
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
            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.periodic(from: startTime, by: 1)) { context in
                    let elapsed = Int(context.date.timeIntervalSince(startTime))
                    Label(
                        "Recording  \(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))",
                        systemImage: "record.circle.fill",
                    )
                    .foregroundStyle(.red)
                }
                if let title = runner.liveMeetingTitle {
                    Label(title, systemImage: "video.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                let names = runner.participantsWatcher.snapshot?
                    .participants
                    .map(\.displayName)
                    .filter { !$0.isEmpty } ?? []
                if !names.isEmpty {
                    Label(names.joined(separator: ", "), systemImage: "person.2.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(names.joined(separator: "\n"))
                }
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
        if let current = runner.currentSession, !selectedSessionIDs.contains(current.path) {
            selectedSessionIDs = [current.path]
            loadDetail(sessionID: current.path)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedSessionIDs) {
            ForEach(groupedSessions, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.sessions) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                            .contextMenu { contextMenuItems(for: session) }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search sessions…")
        .navigationTitle("Transcribeer")
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 380)
        .onDeleteCommand {
            let targets = sessions.filter { selectedSessionIDs.contains($0.id) }
            if !targets.isEmpty { sessionsPendingDeletion = targets }
        }
        .confirmationDialog(
            deletionDialogTitle,
            isPresented: Binding(
                get: { !sessionsPendingDeletion.isEmpty },
                set: { if !$0 { sessionsPendingDeletion = [] } },
            ),
            titleVisibility: .visible,
        ) {
            Button("Move to Trash", role: .destructive) {
                deleteSessions(sessionsPendingDeletion)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deletionDialogMessage)
        }
    }

    /// Sidebar right-click menu — Reveal in Finder, transcribe/summarize
    /// submenus (`SessionContextActions`), then Delete. Built inline because
    /// `contextMenu` accepts a single `@ViewBuilder` closure and inlining
    /// every item bloats the parent `ForEach`.
    @ViewBuilder
    private func contextMenuItems(for session: Session) -> some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.open(session.path)
        }
        Divider()
        SessionContextActions(
            session: session,
            profiles: profiles,
            defaultBackend: TranscriptionBackend.from(config.transcriptionBackend),
            availability: transcriptionAvailability,
            isTranscribingThis: runner.transcribingSession == session.path,
            isSummarizingThis: runner.summarizingSession == session.path,
            onTranscribe: { transcribe(session: session, request: $0) },
            onSummarize: { summarize(session: session, request: $0) }
        )
        Divider()
        Button(deleteMenuTitle(for: session), role: .destructive) {
            sessionsPendingDeletion = deletionTargets(for: session)
        }
    }

    /// When a right-clicked row is part of the current selection and that
    /// selection includes more than one session, "Delete…" acts on the whole
    /// selection. Otherwise it targets just the clicked row so users don't get
    /// surprise bulk deletions when right-clicking an unrelated row.
    private func deletionTargets(for clicked: Session) -> [Session] {
        if selectedSessionIDs.contains(clicked.id), selectedSessionIDs.count > 1 {
            return sessions.filter { selectedSessionIDs.contains($0.id) }
        }
        return [clicked]
    }

    private func deleteMenuTitle(for clicked: Session) -> String {
        let count = deletionTargets(for: clicked).count
        return count > 1 ? "Delete \(count) Sessions…" : "Delete…"
    }

    private var deletionDialogTitle: String {
        switch sessionsPendingDeletion.count {
        case 0: return "Delete session?"
        case 1: return "Delete \"\(sessionsPendingDeletion[0].name)\"?"
        default: return "Delete \(sessionsPendingDeletion.count) sessions?"
        }
    }

    private var deletionDialogMessage: String {
        sessionsPendingDeletion.count > 1
            ? "The recordings, transcripts, and summaries will be moved to the Trash."
            : "The recording, transcript, and summary will be moved to the Trash."
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
                onTranscribe: { request in
                    transcribe(session: session, request: request)
                },
                onSummarize: { request in
                    summarize(session: session, request: request)
                },
                onOpenDir: {
                    NSWorkspace.shared.open(session.path)
                },
                onDelete: {
                    deleteSessions([session])
                },
                onSplit: { splitTime in
                    splitSession(session, at: splitTime)
                }
            )
        } else if selectedSessionIDs.count > 1 {
            ContentUnavailableView(
                "\(selectedSessionIDs.count) Recordings Selected",
                systemImage: "checkmark.circle",
                description: Text("Press Delete to move all selected recordings to the Trash.")
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

    /// Sessions bucketed into Apple Notes–style date groups (Today,
    /// Yesterday, Previous 7 Days, Previous 30 Days, then by year). Empty
    /// buckets are omitted so the sidebar doesn't show hollow section
    /// headers.
    private var groupedSessions: [SessionGroup] {
        SessionGrouper.group(filteredSessions, now: Date())
    }

    private var selectedSession: Session? {
        sessions.first { $0.id == selectedSessionID }
    }

    private func refresh() {
        sessions = SessionManager.listSessions(sessionsDir: config.expandedSessionsDir)
        if selectedSessionIDs.isEmpty, let first = sessions.first {
            selectedSessionIDs = [first.id]
        } else {
            // Drop selections for sessions that no longer exist (e.g. deleted
            // from disk) so the detail pane doesn't show stale rows.
            let existing = Set(sessions.map(\.id))
            let pruned = selectedSessionIDs.intersection(existing)
            if pruned != selectedSessionIDs { selectedSessionIDs = pruned }
        }
    }

    private func loadDetail(sessionID: String?) {
        lastLoadedDetailID = sessionID
        guard let sessionID else {
            detail = nil
            return
        }
        detail = SessionManager.sessionDetail(URL(fileURLWithPath: sessionID))
    }

    /// Run `SessionSplitter` on `session` and, when it succeeds, refresh the
    /// sidebar and jump to the freshly created tail session so the user can
    /// immediately see what was moved out.
    private func splitSession(_ session: Session, at splitTime: TimeInterval) {
        statusText = "Splitting recording\u{2026}"
        Task { @MainActor in
            do {
                let new = try await SessionSplitter.split(
                    session: session.path, at: splitTime, sessionsDir: config.expandedSessionsDir
                )
                refresh()
                selectedSessionIDs = [new.path]
                loadDetail(sessionID: new.path)
                statusText = "Split into a new session."
            } catch {
                statusText = "Split failed: \(error.localizedDescription)"
            }
        }
    }

    private func deleteSessions(_ targets: [Session]) {
        var deleted = 0
        var failed: [String] = []
        for session in targets {
            if SessionManager.deleteSession(session.path) {
                deleted += 1
                selectedSessionIDs.remove(session.id)
            } else {
                failed.append(session.name)
            }
        }
        if deleted > 0, detail != nil, selectedSessionID == nil {
            detail = nil
        }
        statusText = deletionStatus(deleted: deleted, failed: failed)
        refresh()
    }

    private func deletionStatus(deleted: Int, failed: [String]) -> String {
        switch (deleted, failed.count) {
        case (0, 0): return ""
        case (_, 0) where deleted == 1: return "Session moved to Trash."
        case (_, 0): return "\(deleted) sessions moved to Trash."
        case (0, _): return "Failed to delete: \(failed.joined(separator: ", "))"
        default:
            return "\(deleted) deleted; failed: \(failed.joined(separator: ", "))"
        }
    }

    // MARK: - Pipeline actions

    // Shared pipeline entry points for the detail-pane buttons and the
    // sidebar right-click submenus. Status text + post-run detail reload
    // mirror the original closure wiring; the `selectedSessionID` check is
    // a backstop — the primary refresh is `onChange(of: runner.…Session)`.
    private func transcribe(session: Session, request: SessionDetailView.TranscribeRequest) {
        statusText = ""
        let target = session.path
        Task {
            let result = await runner.transcribeSession(
                target,
                config: config,
                languageOverride: request.language,
                backendOverride: request.backend
            )
            statusText = result.ok ? "Transcription done." : "Transcription failed: \(result.error)"
            if selectedSessionID == target.path { loadDetail(sessionID: target.path) }
        }
    }

    private func summarize(session: Session, request: SessionDetailView.SummaryRequest) {
        statusText = "Summarizing…"
        let target = session.path
        let overrides = PipelineRunner.SummarizeOverrides(
            backend: request.backend,
            model: request.model,
            focus: request.focus
        )
        Task {
            let result = await runner.summarizeSession(
                target,
                config: config,
                profile: request.profile,
                overrides: overrides
            )
            statusText = result.ok ? "Summary done." : "Summarization failed: \(result.error)"
            if selectedSessionID == target.path { loadDetail(sessionID: target.path) }
        }
    }

    @MainActor
    private func refreshTranscriptionAvailability() async {
        let resolved = await Task.detached(priority: .utility) {
            TranscriptionBackendAvailability.resolve()
        }.value
        guard !Task.isCancelled else { return }
        transcriptionAvailability = resolved
    }
}

// MARK: - Session row
//
// `SessionRow` itself lives in `SessionRow.swift` so this file stays under
// SwiftLint's file-length cap. Nothing else moves — the row is internal so
// `HistoryView` can keep referencing it as before.
