import AppKit
import SwiftUI
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
    let onTranscribe: (String?) -> Void
    let onSummarize: (SummaryRequest) -> Void
    let onOpenDir: () -> Void
    let onDelete: () -> Void

    /// Everything the detail view wants to override for a single regenerate:
    /// prompt profile, model, and one-shot "focus on X" instructions. A nil
    /// field means "use the app-wide default."
    struct SummaryRequest {
        var profile: String?
        var backend: String?
        var model: String?
        var focus: String?
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
    @State private var progressStartedAt: Date?
    @State private var etaEstimator = ETAEstimator()
    @State private var showDeleteConfirm = false
    @State private var statusClearTask: Task<Void, Never>?
    @State private var summaryStartedAt: Date?
    /// Shared audio player VM. Owned here so the transcript rows can seek
    /// the same player instance the `AudioPlayerView` drives.
    @State private var playerVM = AudioPlayerVM()

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
                AudioPlayerView(audioURL: audioURL, vm: playerVM)
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
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("More actions")

                Button(action: onOpenDir) {
                    Image(systemName: "folder")
                }
                .help("Reveal in Finder")
            }
        }
        .overlay(alignment: .bottom) { statusToast }
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
        .onChange(of: session.id) { _, _ in syncFields() }
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

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Session name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .onSubmit { onRename(name) }

            Text(detail.date + (detail.duration.isEmpty ? "" : " · \(detail.duration)"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
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
        case .summary:
            summaryTabBarAction

        case .transcript:
            HStack(spacing: 8) {
                Picker("Language", selection: $selectedLanguage) {
                    ForEach(TranscriptionLanguage.allCases) { option in
                        Text(option == .auto ? "Default" : option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help("Override the transcription language — 'Default' uses the language from Settings")

                Button {
                    onTranscribe(selectedLanguage.whisperCode)
                } label: {
                    Label("Re-transcribe", systemImage: "waveform.badge.magnifyingglass")
                }
                .controlSize(.small)
                .disabled(!detail.canTranscribe)
            }

        case .notes:
            EmptyView()
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
            SummaryMarkdownView(text: summaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            TranscriptView(
                lines: lines,
                onSeek: { playerVM.seek(to: $0) },
                playheadTime: playerVM.hasAudio ? playerVM.currentTime : nil,
                isStreaming: isTranscribingThisSession,
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Lines to render in the transcript tab.
    ///
    /// While WhisperKit is actively transcribing *this* session, show the live
    /// segments streamed via `segmentDiscoveryCallback` (diarization hasn't
    /// run yet, so speaker is left blank). Otherwise parse the on-disk
    /// transcript — that's the canonical store.
    private var transcriptLines: [TranscriptLine] {
        if isTranscribingThisSession {
            let segments = runner.transcriptionService.liveSegments
                .sorted { $0.start < $1.start }
            return segments.enumerated().map { idx, seg in
                TranscriptLine(
                    id: idx,
                    start: seg.start,
                    end: seg.end,
                    speaker: "…",
                    text: TranscriptFormatter.sanitize(seg.text),
                )
            }
        }
        return TranscriptFormatter.parse(detail.transcript)
    }

    private var isTranscribingThisSession: Bool {
        runner.transcribingSession?.path == session.path.path
    }

    private var notesView: some View {
        TextEditor(text: $notes)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
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

    @ViewBuilder
    private var statusToast: some View {
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

    private var isError: Bool {
        let lower = statusText.lowercased()
        return lower.contains("failed") || lower.contains("error")
    }

    private func scheduleStatusClear(for newValue: String) {
        statusClearTask?.cancel()
        guard !newValue.isEmpty, !newValue.hasSuffix("…") else { return }
        statusClearTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(isError ? 6 : 3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { statusText = "" }
        }
    }

    // MARK: - Export

    private func exportTranscript() {
        export(content: detail.transcript, defaultName: "transcript", ext: "txt")
    }

    private func exportSummary() {
        export(content: detail.summary, defaultName: "summary", ext: "md")
    }

    private func export(content: String, defaultName: String, ext: String) {
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

    // MARK: - Progress row

    private var showProgressRow: Bool {
        runner.transcriptionProgress != nil
            || runner.transcriptionService.modelState.isBusy
    }
}
