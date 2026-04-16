import TranscribeerCore
import SwiftUI

struct SessionDetailView: View {
    let session: Session
    let detail: SessionDetail
    let profiles: [String]
    @Binding var statusText: String
    let onRename: (String) -> Void
    let onSaveNotes: (String) -> Void
    let onTranscribe: () -> Void
    let onSummarize: (String?) -> Void
    let onOpenDir: () -> Void

    @State private var name: String = ""
    @State private var notes: String = ""
    @State private var selectedTab = 0
    @State private var selectedProfile = "default"
    @State private var notesSaveTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                TextField("Session name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title2.bold())
                    .onSubmit { onRename(name) }

                Text(detail.date + (detail.duration.isEmpty ? "" : " · \(detail.duration)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            // Audio player
            if let audioURL = detail.audioURL {
                Divider()
                AudioPlayerView(audioURL: audioURL)
            }

            Divider()

            // Notes
            VStack(alignment: .leading, spacing: 4) {
                Text("Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 40, maxHeight: 60)
                    .scrollContentBackground(.hidden)
                    .onChange(of: notes) { _, newValue in
                        notesSaveTask?.cancel()
                        notesSaveTask = Task {
                            try? await Task.sleep(for: .milliseconds(500))
                            guard !Task.isCancelled else { return }
                            onSaveNotes(newValue)
                        }
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            Divider()

            // Content tabs
            Picker("", selection: $selectedTab) {
                Text("Summary").tag(0)
                Text("Transcript").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            ScrollView {
                if selectedTab == 0 {
                    if detail.summary.isEmpty {
                        Text("No summary yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .italic()
                            .padding(20)
                    } else {
                        Text(detail.summary)
                            .font(.callout)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .padding(20)
                    }
                } else {
                    if detail.transcript.isEmpty {
                        Text("No transcript yet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .italic()
                            .padding(20)
                    } else {
                        Text(detail.transcript)
                            .font(.system(.caption, design: .monospaced))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .padding(20)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Bottom bar
            HStack {
                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(
                            statusText.contains("failed") || statusText.contains("error")
                                ? .red : .secondary
                        )
                }
                Spacer()
                Button("Open in Finder") { onOpenDir() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Re-transcribe") { onTranscribe() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!detail.canTranscribe)

                Picker("Profile", selection: $selectedProfile) {
                    ForEach(profiles, id: \.self) { p in
                        Text(p).tag(p)
                    }
                }
                .frame(width: 100)
                .controlSize(.small)

                Button("Re-summarize") {
                    onSummarize(selectedProfile == "default" ? nil : selectedProfile)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!detail.canSummarize)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .onAppear {
            name = detail.name
            notes = detail.notes
        }
        .onChange(of: session.id) { _, _ in
            name = detail.name
            notes = detail.notes
        }
    }

}
