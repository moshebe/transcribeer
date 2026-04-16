import TranscribeerCore
import SwiftUI

struct HistoryView: View {
    @Binding var config: AppConfig
    let runner: PipelineRunner

    @State private var sessions: [Session] = []
    @State private var selectedSessionID: String?
    @State private var detail: SessionDetail?
    @State private var searchText = ""
    @State private var profiles: [String] = ["default"]
    @State private var statusText = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailPanel
        }
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
            refresh()
            profiles = PromptProfileManager.listProfiles()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("🍺 Transcribeer")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            List(filteredSessions, selection: $selectedSessionID) { session in
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.callout.weight(session.isUntitled ? .regular : .semibold))
                        .foregroundStyle(session.isUntitled ? .secondary : .primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(session.formattedDate)
                        if !session.duration.isEmpty && session.duration != "—" {
                            Text("·")
                            Text(session.duration)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    if !session.snippet.isEmpty {
                        Text(session.snippet)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .italic()
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
            }
            .searchable(text: $searchText, prompt: "Search sessions…")
        }
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
                statusText: $statusText,
                onRename: { newName in
                    SessionManager.setName(session.path, newName)
                    refresh()
                },
                onSaveNotes: { newNotes in
                    SessionManager.setNotes(session.path, newNotes)
                },
                onTranscribe: {
                    statusText = "Transcribing…"
                    Task {
                        let r = await runner.transcribeSession(session.path, config: config)
                        statusText = r.ok ? "Transcription done." : "Transcription failed: \(r.error)"
                        loadDetail(sessionID: selectedSessionID)
                    }
                },
                onSummarize: { profile in
                    statusText = "Summarizing…"
                    Task {
                        let r = await runner.summarizeSession(
                            session.path, config: config, profile: profile
                        )
                        statusText = r.ok ? "Summary done." : "Summarization failed: \(r.error)"
                        loadDetail(sessionID: selectedSessionID)
                    }
                },
                onOpenDir: {
                    NSWorkspace.shared.open(session.path)
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
        guard let id = sessionID else {
            detail = nil
            return
        }
        let url = URL(fileURLWithPath: id)
        detail = SessionManager.sessionDetail(url)
    }
}
