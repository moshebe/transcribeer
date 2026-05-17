import SwiftUI

/// Re-transcribe controls for the Transcript tab: a language picker plus a
/// split-button that re-transcribes with the configured default backend on
/// the primary action and exposes alternates (e.g. fall back to OpenAI when
/// WhisperKit struggles with a noisy recording) on the chevron. Cloud
/// backends without an API key are listed but disabled so the menu still
/// tells the user which options exist and what's blocking them.
///
/// Lives in its own file to keep `SessionDetailView` under SwiftLint's
/// `type_body_length` cap and so the language + backend overrides ship as a
/// single composable widget.
struct RetranscribeMenu: View {
    let config: AppConfig
    @Binding var language: TranscriptionLanguage
    let canTranscribe: Bool
    let onTranscribe: (SessionDetailView.TranscribeRequest) -> Void

    @State private var availability = TranscriptionBackendAvailability.localOnly

    var body: some View {
        HStack(spacing: 8) {
            languagePicker
            backendMenu
        }
        .task(id: config.transcriptionBackend) { await refreshAvailability() }
    }

    private var languagePicker: some View {
        Picker("Language", selection: $language) {
            ForEach(TranscriptionLanguage.allCases) { option in
                Text(option == .auto ? "Default" : option.displayName).tag(option)
            }
        }
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .help("Override the transcription language — 'Default' uses the language from Settings")
    }

    private var backendMenu: some View {
        let defaultBackend = TranscriptionBackend.from(config.transcriptionBackend)
        return Menu {
            ForEach(TranscriptionBackend.allCases) { backend in
                Button {
                    onTranscribe(.init(
                        language: language.whisperCode,
                        backend: backend.rawValue,
                    ))
                } label: {
                    Text(label(for: backend, default: defaultBackend))
                }
                .disabled(!isAvailable(backend))
            }
        } label: {
            Label("Re-transcribe", systemImage: "waveform.badge.magnifyingglass")
        } primaryAction: {
            onTranscribe(.init(language: language.whisperCode, backend: nil))
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .disabled(!canTranscribe)
        .help("Click to re-transcribe with \(defaultBackend.displayName) — " +
              "use the chevron to pick a different backend.")
    }

    private func label(
        for backend: TranscriptionBackend,
        default defaultBackend: TranscriptionBackend
    ) -> String {
        var text = backend.displayName
        if backend == defaultBackend {
            text += " (default)"
        } else if backend.usesAPIKey, !availability.isAvailable(backend) {
            text += " — no API key"
        }
        return text
    }

    @MainActor
    private func refreshAvailability() async {
        let resolved = await Task.detached(priority: .utility) {
            TranscriptionBackendAvailability.resolve()
        }.value
        guard !Task.isCancelled else { return }
        availability = resolved
    }

    private func isAvailable(_ backend: TranscriptionBackend) -> Bool {
        availability.isAvailable(backend)
    }
}
