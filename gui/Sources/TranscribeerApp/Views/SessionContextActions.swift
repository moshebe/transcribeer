import SwiftUI

/// Right-click submenu items for a session row in the sidebar.
///
/// Surfaces the same two pipeline actions as the detail-pane toolbar:
/// transcription (with a per-backend submenu mirroring `RetranscribeMenu`'s
/// split-button) and summarization (with a per-profile submenu mirroring
/// `SummaryControlsRow`'s profile picker). Lives in its own type so the
/// host `HistoryView` stays under the file-length cap and so the action
/// closures stay explicit instead of reaching into the parent's private
/// state.
///
/// Designed to be embedded directly inside a `.contextMenu { ... }` block
/// alongside other items (Reveal in Finder, Delete) — it renders two `Menu`
/// items, no chrome, no divider.
struct SessionContextActions: View {
    let session: Session
    let profiles: [String]
    let defaultBackend: TranscriptionBackend
    let availability: TranscriptionBackendAvailability
    /// True iff a pipeline run is currently transcribing/summarizing *this*
    /// session — the matching menu disables itself so the user can't queue
    /// a second concurrent run on the same row.
    let isTranscribingThis: Bool
    let isSummarizingThis: Bool

    let onTranscribe: (SessionDetailView.TranscribeRequest) -> Void
    let onSummarize: (SessionDetailView.SummaryRequest) -> Void

    var body: some View {
        transcribeMenu
        summarizeMenu
    }

    @ViewBuilder
    private var transcribeMenu: some View {
        let canTranscribe = session.hasAudio && !isTranscribingThis
        Menu("Transcribe") {
            Button("Default (\(defaultBackend.displayName))") {
                onTranscribe(.init(language: nil, backend: nil))
            }
            Divider()
            ForEach(TranscriptionBackend.allCases) { backend in
                Button(label(for: backend)) {
                    onTranscribe(.init(language: nil, backend: backend.rawValue))
                }
                .disabled(!availability.isAvailable(backend))
            }
        }
        .disabled(!canTranscribe)
    }

    @ViewBuilder
    private var summarizeMenu: some View {
        let canSummarize = session.hasTranscript && !isSummarizingThis
        Menu("Summarize") {
            Button("Default Profile") {
                onSummarize(.init(profile: nil))
            }
            if !profiles.isEmpty { Divider() }
            // `default` is the implicit profile already covered by the top
            // entry; passing `nil` keeps the request semantically "use the
            // default" instead of pinning to a profile literally named
            // "default" (the runner treats them identically today, but a
            // future rename would break the pin).
            ForEach(profiles, id: \.self) { profile in
                Button(profile) {
                    onSummarize(.init(profile: profile == "default" ? nil : profile))
                }
            }
        }
        .disabled(!canSummarize)
    }

    private func label(for backend: TranscriptionBackend) -> String {
        if backend == defaultBackend {
            return "\(backend.displayName) (default)"
        }
        if backend.usesAPIKey, !availability.isAvailable(backend) {
            return "\(backend.displayName) — no API key"
        }
        return backend.displayName
    }
}
