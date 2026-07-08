import AppKit
import SwiftUI
import TranscribeerCore
import WhisperKit

struct SessionDetailView: View {
    let session: Session
    let detail: SessionDetail
    let profiles: [String]
    let runner: PipelineRunner
    /// Used to seed the summary model picker with the app-wide default and
    /// to resolve the Ollama host when fetching live model tags.
    let config: AppConfig
    @Binding var statusText: String
    let onRename: (String) -> Void
    let onSaveNotes: (String) -> Void
    let onTranscribe: (TranscribeRequest) -> Void
    let onSummarize: (SummaryRequest) -> Void
    let onOpenDir: () -> Void
    let onDelete: () -> Void
    let onSplit: (TimeInterval) -> Void

    /// Everything the detail view wants to override for a single regenerate:
    /// prompt profile, model, and one-shot "focus on X" instructions. A nil
    /// field means "use the app-wide default."
    struct SummaryRequest {
        var profile: String?
        var backend: String?
        var model: String?
        var focus: String?
    }

    /// Per-call overrides for re-transcribe. `nil` means "use the app-wide
    /// default". `language` is the Whisper-style code, `backend` is the
    /// `TranscriptionBackend` raw value.
    struct TranscribeRequest {
        var language: String?
        var backend: String?
    }

    @State private var name: String = ""
    @State private var notes: String = ""
    @State private var activeTab: Tab = .summary
    @State private var selectedProfile = "default"
    @State private var selectedSummaryModel: SummaryModelOption?
    @State private var summaryFocus: String = ""
    @State private var summaryModelOptions: [SummaryModelOption] = []
    @State private var selectedLanguage: TranscriptionLanguage = .auto
    @State private var notesSaveTask: Task<Void, Never>?
    @State private var nameSaveTask: Task<Void, Never>?
    @State private var progressStartedAt: Date?
    @State private var etaEstimator = ETAEstimator()
    @State private var showDeleteConfirm = false
    @State private var statusClearTask: Task<Void, Never>?
    @State private var summaryStartedAt: Date?
    /// Shared audio player VM. Owned here so the transcript rows can seek
    /// the same player instance the `AudioPlayerView` drives.
    @State private var playerVM = AudioPlayerVM()

    // Find (⌘F) state, shared across the summary / transcript / notes tabs.
    @State private var findVisible = false
    @State private var findQuery = ""
    @State private var findIndex = 0
    @FocusState private var findFocused: Bool

    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case transcript = "Transcript"
        case notes = "Notes"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let audioURL = detail.audioURL {
                AudioPlayerView(
                    audioURL: audioURL,
                    vm: playerVM,
                    onSplit: onSplit
                )
            }

            Divider()

            tabBar

            tabContent

            if showProgressRow {
                Divider()
                TranscriptionProgressRow(
                    runner: runner,
                    startedAt: progressStartedAt,
                    etaEstimator: etaEstimator,
                )
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Export Transcript…", action: exportTranscript)
                        .disabled(detail.transcript.isEmpty)
                    Button("Export Summary…", action: exportSummary)
                        .disabled(detail.summary.isEmpty)
                    Divider()
                    Button("Delete Session…", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    .keyboardShortcut(.delete, modifiers: .command)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("More actions")
                .accessibilityLabel("More actions")

                Button(action: onOpenDir) {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal in Finder")
            }
        }
        .background {
            Button("Find", action: openFind)
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .overlay(alignment: .topTrailing) { findBar }
        .overlay(alignment: .bottom) { statusToast }
        .onChange(of: findQuery) { _, _ in findIndex = 0 }
        .onChange(of: activeTab) { _, _ in findIndex = 0 }
        .confirmationDialog(
            "Delete \"\(detail.name.isEmpty ? session.name : detail.name)\"?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible,
        ) {
            Button("Move to Trash", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The session folder will be moved to the Trash.")
        }
        .onAppear { syncFields() }
        // `.task(id:)` runs on first appear *and* whenever the host changes,
        // so there's no need for a separate plain `.task`.
        .task(id: config.ollamaHost) { await refreshSummaryModels() }
        .onChange(of: session.id) { _, _ in
            // Cancel any pending debounced rename — it would fire with the
            // outgoing session's local `name` value but the `onRename` closure
            // already captures the *incoming* session (closures are rebuilt by
            // the parent on every render). Calling it would write the wrong
            // name to the wrong session, which is the root cause of the
            // sidebar/detail desync bug (commit 5a64318).
            //
            // The 400 ms debounce means any edit that the user committed
            // (stopped typing for ≥ 400 ms) is already on disk before they
            // could switch sessions. Sub-400 ms tail-edits are dropped on
            // session switch — the same trade-off every debounced macOS text
            // field makes.
            nameSaveTask?.cancel()
            nameSaveTask = nil
            syncFields()
        }
        // Work around the state-sync race where this view is rendered with a
        // new `session` but the parent's `detail` state hasn't caught up yet
        // (parent updates `detail` in its own `.onChange`, which runs after
        // this body). When the detail eventually catches up, re-sync the
        // local editable fields — but only if the user hasn't started typing
        // (local value still matches the previous `detail.*`).
        .onChange(of: detail.name) { oldValue, newValue in
            // Sync model → local state only when the user hasn't made an unsaved
            // edit (i.e. local still matches the previous detail value). This
            // prevents the parent's late update from overwriting an in-flight edit.
            if name == oldValue {
                nameSaveTask?.cancel()
                name = newValue
            }
        }
        .onChange(of: detail.notes) { oldValue, newValue in
            if notes == oldValue { notes = newValue }
        }
        .onChange(of: detail.language) { _, _ in syncLanguage() }
        .onChange(of: statusText) { _, newValue in scheduleStatusClear(for: newValue) }
        .onChange(of: showProgressRow) { _, isVisible in
            progressStartedAt = isVisible ? (progressStartedAt ?? Date()) : nil
            if !isVisible { etaEstimator.reset() }
        }
        .onChange(of: isSummarizingThisSession) { _, isActive in
            summaryStartedAt = isActive ? (summaryStartedAt ?? Date()) : nil
        }
    }

    /// Reset per-session editable state. Called on first load and whenever
    /// the selected session changes so nothing leaks between sessions.
    private func syncFields() {
        name = detail.name
        notes = detail.notes
        summaryFocus = ""
        selectedSummaryModel = defaultSummaryModel
        syncLanguage()
    }

    private var defaultSummaryModel: SummaryModelOption {
        SummaryModelOption(
            backend: LLMBackend.from(config.llmBackend),
            model: config.llmModel,
        )
    }

    /// Fetch live Ollama tags + combine with the static catalog so the model
    /// picker reflects both cloud models and whatever the user has pulled
    /// locally. Runs on first appearance and when the Ollama host changes.
    private func refreshSummaryModels() async {
        let ollamaModels = await SummarizationCatalog.fetchOllamaModels(host: config.ollamaHost)
        let options = SummarizationCatalog.optionsIncludingDefault(
            default: defaultSummaryModel,
            ollamaModels: ollamaModels,
        )
        summaryModelOptions = options
        if let current = selectedSummaryModel,
           !options.contains(where: { $0.id == current.id }) {
            selectedSummaryModel = defaultSummaryModel
        }
    }

    private func syncLanguage() {
        selectedLanguage = detail.language.map(TranscriptionLanguage.from) ?? .auto
    }

    // MARK: - Debounced rename

    private func scheduleRename(_ newName: String) {
        // Ignore model-driven updates (detail.name sync) — only save user edits.
        guard newName != detail.name else { return }
        nameSaveTask?.cancel()
        nameSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await MainActor.run { onRename(newName) }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Session name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .onSubmit {
                    nameSaveTask?.cancel()
                    onRename(name)
                }
                .onChange(of: name) { _, newValue in
                    scheduleRename(newValue)
                }

            Text(detail.date + (detail.duration.isEmpty ? "" : " · \(detail.duration)"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if let lang = detail.detectedLanguage {
                detectedLanguageChip(lang)
            }

            if !detail.participants.isEmpty {
                SessionParticipantsRow(participants: detail.participants)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    // MARK: - Detected language chip

    private func detectedLanguageChip(_ lang: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text("Detected: \(TranscriptionLanguage.displayName(for: lang))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Menu {
                Button("Re-transcribe as Hebrew") {
                    onTranscribe(.init(language: TranscriptionLanguage.hebrew.rawValue, backend: nil))
                }
                Button("Re-transcribe as English") {
                    onTranscribe(.init(language: TranscriptionLanguage.english.rawValue, backend: nil))
                }
                Button("Re-transcribe (auto-detect)") {
                    onTranscribe(.init(language: nil, backend: nil))
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $activeTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            contextualAction
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var contextualAction: some View {
        switch activeTab {
        case .summary: summaryTabBarAction
        case .transcript:
            RetranscribeMenu(
                config: config,
                language: $selectedLanguage,
                canTranscribe: detail.canTranscribe,
                onTranscribe: onTranscribe,
            )
        case .notes: EmptyView()
        }
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .summary: summaryView
        case .transcript: transcriptView
        case .notes: notesView
        }
    }

    /// Regenerate button — the only summary-tab action that fits on the tab
    /// bar row. Profile / model / focus live in their own controls row below
    /// so people aren't scrolled sideways on smaller windows.
    private var summaryTabBarAction: some View {
        Button {
            triggerSummarize()
        } label: {
            Label(
                isSummarizingThisSession ? "Stop" : "Regenerate",
                systemImage: isSummarizingThisSession ? "stop.fill" : "arrow.clockwise",
            )
        }
        .controlSize(.small)
        .disabled(!detail.canSummarize && !isSummarizingThisSession)
        .help(isSummarizingThisSession
              ? "Stop the current summarization"
              : "Regenerate summary with the options below")
    }

    private func triggerSummarize() {
        guard !isSummarizingThisSession else {
            runner.cancelProcessing()
            return
        }
        onSummarize(.init(
            profile: selectedProfile == "default" ? nil : selectedProfile,
            backend: selectedSummaryModel?.backend.rawValue,
            model: selectedSummaryModel?.model,
            focus: summaryFocus.trimmingCharacters(in: .whitespacesAndNewlines),
        ))
    }

    private var summaryView: some View {
        VStack(spacing: 0) {
            summaryControlsRow
            Divider()
            summaryBody
        }
    }

    @ViewBuilder
    private var summaryBody: some View {
        if summaryText.isEmpty {
            ScrollView {
                emptyState(isSummarizingThisSession ? "Summarizing…" : "No summary yet.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                usageStrip(detail.summarizationUsage, hidden: isSummarizingThisSession)
                SummaryMarkdownView(
                    text: summaryText,
                    searchQuery: findVisible ? findQuery : "",
                    activeOccurrence: findVisible ? clampedIndex(matchCount) : nil,
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// While the LLM is streaming for *this* session, render the in-memory
    /// accumulator so users see text land as it arrives. Otherwise show the
    /// on-disk summary — that's the canonical store.
    private var summaryText: String {
        isSummarizingThisSession ? runner.liveSummary : detail.summary
    }

    private var isSummarizingThisSession: Bool {
        runner.summarizingSession?.path == session.path.path
    }

    // MARK: - Summary controls row

    private var summaryControlsRow: some View {
        SummaryControlsRow(
            profiles: profiles,
            modelOptions: summaryModelOptions,
            isBusy: isSummarizingThisSession,
            summaryStartedAt: summaryStartedAt,
            selectedProfile: $selectedProfile,
            selectedModel: $selectedSummaryModel,
            focus: $summaryFocus,
            onSubmit: triggerSummarize,
        )
    }

    @ViewBuilder
    private var transcriptView: some View {
        let lines = transcriptLines
        if lines.isEmpty {
            ScrollView {
                emptyState(isTranscribingThisSession ? "Starting transcription…" : "No transcript yet.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let match = activeTranscriptMatch(in: lines)
            VStack(spacing: 0) {
                usageStrip(detail.transcriptionUsage, hidden: isTranscribingThisSession)
                TranscriptView(
                    lines: lines,
                    onSeek: { playerVM.seek(to: $0) },
                    playheadTime: playerVM.hasAudio ? playerVM.currentTime : nil,
                    isStreaming: isTranscribingThisSession,
                    otherLabel: config.audio.otherLabel,
                    searchQuery: findVisible ? findQuery : "",
                    activeLineIndex: match?.lineIndex,
                    activeOccurrence: match?.occurrence,
                    searchToken: findIndex,
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var isTranscribingThisSession: Bool {
        runner.transcribingSession?.path == session.path.path
    }

    private var notesView: some View {
        NotesEditor(
            text: $notes,
            searchQuery: findVisible ? findQuery : "",
            activeOccurrence: findVisible ? clampedIndex(matchCount) : nil,
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: notes) { _, newValue in
                notesSaveTask?.cancel()
                notesSaveTask = Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    onSaveNotes(newValue)
                }
            }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .italic()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
    }

    // MARK: - Status toast

    private var statusToast: some View {
        SessionStatusToast(statusText: $statusText)
    }

    private func scheduleStatusClear(for newValue: String) {
        statusClearTask?.cancel()
        guard !newValue.isEmpty, !newValue.hasSuffix("…") else { return }
        let hasError = newValue.lowercased().contains("failed")
            || newValue.lowercased().contains("error")
        statusClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(hasError ? 6 : 3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { statusText = "" }
        }
    }

    // MARK: - Progress row

    private var showProgressRow: Bool {
        runner.transcriptionProgress != nil
            || runner.transcriptionService.modelState.isBusy
    }
}

// MARK: - SessionDetailView: transcript helpers + export

private extension SessionDetailView {
    /// Leading-aligned strip of pipeline-usage badges shown above the summary
    /// and transcript bodies. Hidden while the corresponding stage is streaming,
    /// since mid-run metadata is stale.
    @ViewBuilder
    func usageStrip(_ usage: PipelineUsage?, hidden: Bool) -> some View {
        if let usage, !hidden {
            HStack { PipelineUsageBadges(usage: usage); Spacer() }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
    }

    /// Lines to render in the transcript tab.
    ///
    /// While WhisperKit is actively transcribing *this* session, show the live
    /// segments. For dual-source transcription the speaker label is already
    /// known (self / other); for legacy single-file it shows "…" until the
    /// diarization pass completes.
    var transcriptLines: [TranscriptLine] {
        if isTranscribingThisSession {
            let segments = runner.transcriptionService.liveSegments
                .sorted { $0.start < $1.start }
            return segments.enumerated().map { idx, seg in
                TranscriptLine(
                    id: idx,
                    start: seg.start,
                    end: seg.end,
                    speaker: seg.speaker.isEmpty ? "…" : seg.speaker,
                    text: TranscriptFormatter.sanitize(seg.text),
                )
            }
        }
        return TranscriptFormatter.parse(detail.transcript)
    }

    func exportTranscript() {
        export(content: detail.transcript, defaultName: "transcript", ext: "txt")
    }

    func exportSummary() {
        export(content: detail.summary, defaultName: "summary", ext: "md")
    }

    func export(content: String, defaultName: String, ext: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(detail.name.isEmpty ? defaultName : detail.name).\(ext)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            statusText = "Exported to \(url.lastPathComponent)."
        } catch {
            statusText = "Export failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - SessionDetailView: find (⌘F)

private extension SessionDetailView {
    @ViewBuilder
    var findBar: some View {
        if findVisible {
            let count = matchCount
            FindBar(
                query: $findQuery,
                matchCount: count,
                currentIndex: clampedIndex(count),
                onNext: nextMatch,
                onPrev: prevMatch,
                onClose: closeFind,
                focused: $findFocused,
            )
            .padding(12)
        }
    }

    func openFind() {
        findVisible = true
        DispatchQueue.main.async { findFocused = true }
    }

    func closeFind() {
        findVisible = false
        findQuery = ""
        findIndex = 0
    }

    func nextMatch() {
        guard matchCount > 0 else { return }
        findIndex = (findIndex + 1) % matchCount
    }

    func prevMatch() {
        guard matchCount > 0 else { return }
        findIndex = (findIndex - 1 + matchCount) % matchCount
    }

    /// Match count for the currently active tab. Drives the find bar label
    /// and navigation wrap-around.
    var matchCount: Int {
        guard findVisible, !findQuery.isEmpty else { return 0 }
        switch activeTab {
        case .transcript: return transcriptMatchLocations(in: transcriptLines).count
        case .summary: return TextMatcher.count(of: findQuery, in: summaryText)
        case .notes: return TextMatcher.count(of: findQuery, in: notes)
        }
    }

    func clampedIndex(_ count: Int) -> Int {
        count > 0 ? min(findIndex, count - 1) : 0
    }

    /// Flat list of transcript matches in reading order, each tagged with the
    /// line's array index and its occurrence within that line.
    func transcriptMatchLocations(in lines: [TranscriptLine]) -> [(lineIndex: Int, occurrence: Int)] {
        guard !findQuery.isEmpty else { return [] }
        var locations: [(Int, Int)] = []
        for (index, line) in lines.enumerated() {
            let count = TextMatcher.count(of: findQuery, in: line.text)
            for occurrence in 0..<count { locations.append((index, occurrence)) }
        }
        return locations
    }

    func activeTranscriptMatch(in lines: [TranscriptLine]) -> (lineIndex: Int, occurrence: Int)? {
        guard findVisible else { return nil }
        let locations = transcriptMatchLocations(in: lines)
        guard !locations.isEmpty else { return nil }
        return locations[clampedIndex(locations.count)]
    }
}

// MARK: - SessionStatusToast

/// Floating pill shown at the bottom of the session detail view for
/// transient status messages (export success, errors, etc.).
/// Extracted to keep `SessionDetailView`'s body line count within limits.
private struct SessionStatusToast: View {
    @Binding var statusText: String

    private var isError: Bool {
        let lower = statusText.lowercased()
        return lower.contains("failed") || lower.contains("error")
    }

    var body: some View {
        if !statusText.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? .red : .green)
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.separator.opacity(0.3), lineWidth: 1),
            )
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
