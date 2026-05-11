import SwiftUI

/// Transcription tab of the Settings window.
///
/// Split out from `SettingsView` so the parent file stays under SwiftLint's
/// `file_length` cap and so the cloud-vs-local UI branching has its own home.
/// The view is intentionally dumb: state and persistence stay in the parent
/// via `@Binding`, and the API key is passed in so the parent can rehydrate
/// it from the Keychain when the backend changes.
struct TranscriptionSettingsView: View {
    @Binding var config: AppConfig
    @Binding var apiKey: String
    var save: () -> Void
    var reloadAPIKey: () -> Void

    @State private var modelCatalog = ModelCatalogService()

    private var backend: TranscriptionBackend {
        TranscriptionBackend.from(config.transcriptionBackend)
    }

    var body: some View {
        Form {
            backendSection
            if backend == .whisperkit {
                whisperKitSection
            } else {
                cloudSection
            }
            languageSection
            if backend == .whisperkit {
                diarizationSection
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .task {
            // Make sure whatever the user has selected is visible in the
            // picker, then refresh from the network. If refresh fails the
            // pre-seeded entry keeps the UI usable.
            modelCatalog.ensureEntry(for: AppConfig.canonicalWhisperModel(config.whisperModel))
            await modelCatalog.refresh()
            modelCatalog.ensureEntry(for: AppConfig.canonicalWhisperModel(config.whisperModel))
        }
    }

    // MARK: - Backend picker

    private var backendSection: some View {
        Section {
            Picker("Backend", selection: Binding(
                get: { backend },
                set: { newBackend in
                    config.transcriptionBackend = newBackend.rawValue
                    save()
                    reloadAPIKey()
                },
            )) {
                ForEach(TranscriptionBackend.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } header: {
            Text("Backend")
        } footer: {
            Text(backend == .whisperkit
                 ? "Runs Whisper locally on the Apple Neural Engine. No data leaves the machine."
                 : "Sends audio to \(backend.displayName) for transcription. Requires an API key.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - WhisperKit (local)

    @ViewBuilder
    private var whisperKitSection: some View {
        Section {
            modelPicker
            TextField("Custom model repo (optional)", text: Binding(
                get: { config.whisperModelRepo },
                set: { config.whisperModelRepo = $0 },
            ))
            .onSubmit { save() }
        } header: {
            whisperHeader
        } footer: {
            whisperFooter
        }
    }

    private var whisperHeader: some View {
        HStack {
            Text("Whisper model")
            Spacer()
            if modelCatalog.isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await modelCatalog.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh model list")
                .accessibilityLabel("Refresh model list")
            }
        }
    }

    private var whisperFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Models are downloaded on first use (~0.1–1.5 GB). Stored in ~/.transcribeer/models/.")
            Text("Custom repo: HuggingFace repo for ivrit-ai or other fine-tuned models")
            Text("(e.g. owner/ivrit-ai-whisper-large-v3-turbo-coreml).")
            if let message = modelCatalog.lastError {
                Text(message).foregroundStyle(.orange)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var modelPicker: some View {
        let selected = AppConfig.canonicalWhisperModel(config.whisperModel)
        return Picker("Model", selection: Binding(
            get: { selected },
            set: { config.whisperModel = $0; save() },
        )) {
            if modelCatalog.entries.isEmpty {
                Text(selected).tag(selected)
            } else {
                ForEach(modelCatalog.entries) { entry in
                    ModelPickerRow(entry: entry).tag(entry.id)
                }
            }
        }
        .pickerStyle(.menu)
        .disabled(modelCatalog.entries.isEmpty)
    }

    // MARK: - Cloud (OpenAI / Gemini)

    @ViewBuilder
    private var cloudSection: some View {
        Section {
            TextField("Model", text: cloudModelBinding)
                .onSubmit { save() }
            SecureField("API key", text: $apiKey)
                .onSubmit {
                    guard !apiKey.isEmpty else { return }
                    KeychainHelper.setAPIKey(backend: backend.keychainKey, key: apiKey)
                }
            TranscriptionAPIKeyStatus(backend: backend, keychainKey: apiKey)
        } header: {
            Text("\(backend.displayName) settings")
        } footer: {
            Text(cloudFooter)
                .foregroundStyle(.secondary)
        }
    }

    private var cloudModelBinding: Binding<String> {
        Binding(
            get: {
                backend == .openai
                    ? config.openaiTranscriptionModel
                    : config.geminiTranscriptionModel
            },
            set: { newValue in
                if backend == .openai {
                    config.openaiTranscriptionModel = newValue
                } else {
                    config.geminiTranscriptionModel = newValue
                }
            },
        )
    }

    private var cloudFooter: String {
        switch backend {
        case .whisperkit:
            return ""
        case .openai:
            return "`whisper-1` is the only OpenAI audio model that returns segment-level "
                + "timestamps. `gpt-4o-transcribe` works but falls back to one segment per chunk. "
                + "Long files are split into 10-min chunks."
        case .gemini:
            return "Use a Google AI Studio key. Audio is sent inline; long recordings are split "
                + "into 10-min chunks. Defaults to gemini-2.5-flash; gemini-2.5-pro works too "
                + "but is slower."
        }
    }

    // MARK: - Shared sections

    private var languageSection: some View {
        Section {
            Picker("Language", selection: Binding(
                get: { TranscriptionLanguage.from(config.language) },
                set: { config.language = $0.rawValue; save() },
            )) {
                ForEach(TranscriptionLanguage.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
        } header: {
            Text("Language")
        } footer: {
            Text(languageFooterText)
                .foregroundStyle(.secondary)
        }
    }

    private var languageFooterText: String {
        if config.language == "auto" {
            return "Auto-detect runs a language-ID pass before transcription. "
                + "Explicit selection is faster and more reliable — recommended "
                + "if you only record in one or two languages."
        }
        let name = TranscriptionLanguage.from(config.language).displayName
        return "Whisper will transcribe as \(name). Override per-session from the transcript tab."
    }

    private var diarizationSection: some View {
        Section {
            Picker("Speaker detection", selection: Binding(
                get: { config.diarization },
                set: { config.diarization = $0; save() },
            )) {
                Text("pyannote").tag("pyannote")
                Text("none").tag("none")
            }
        } header: {
            Text("Diarization")
        } footer: {
            Text(config.diarization == "none"
                 ? "Disabled — transcript will have a single unlabelled speaker."
                 : "Detects and labels multiple speakers in the transcript.")
                .foregroundStyle(.secondary)
        }
    }
}

/// Whisper-model picker row (label + status badges). Used both as the picker's
/// collapsed label and inside its menu — duplicating the layout in two
/// places would drift over time.
struct ModelPickerRow: View {
    let entry: WhisperModelEntry

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.displayName)
            if entry.isRecommendedDefault {
                Text("default").modifier(SettingsBadgeStyle(tint: .accentColor))
            }
            if entry.isDownloaded {
                Text("downloaded").modifier(SettingsBadgeStyle(tint: .green))
            }
            if entry.isDisabled {
                Text("unsupported").modifier(SettingsBadgeStyle(tint: .secondary))
            }
        }
    }
}

/// API-key status pill for the Transcription tab. Mirrors `APIKeyStatus`
/// (in `SettingsView.swift`) but reads from `TranscriptionBackend` so
/// summarization and transcription keep separate Keychain slots — Gemini
/// transcription stores an API key while Gemini summarization auths via
/// gcloud ADC.
struct TranscriptionAPIKeyStatus: View {
    let backend: TranscriptionBackend
    let keychainKey: String

    var body: some View {
        let kcPresent = !keychainKey.isEmpty
        let envName = backend.envVar
        let envPresent = envName.map { Self.envHasValue($0) } ?? false
        let altEnvPresent = backend == .gemini && Self.envHasValue("GOOGLE_API_KEY")
        let anyEnvPresent = envPresent || altEnvPresent

        HStack(spacing: 6) {
            icon(keychainPresent: kcPresent, envValuePresent: anyEnvPresent)
            Text(title(keychainPresent: kcPresent, envValuePresent: anyEnvPresent))
                .font(.caption)
            if envPresent, let envName {
                badge(name: envName)
            } else if altEnvPresent {
                badge(name: "GOOGLE_API_KEY")
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func badge(name: String) -> some View {
        Text("$\(name)")
            .modifier(SettingsBadgeStyle(tint: .green, font: .caption.monospaced()))
            .help("Detected in your login shell environment")
    }

    private func icon(keychainPresent: Bool, envValuePresent: Bool) -> some View {
        let kind: SettingsStatusIcon.Kind
        let label: String
        switch (keychainPresent, envValuePresent) {
        case (true, _):      kind = .ok;      label = "API key stored in Keychain"
        case (false, true):  kind = .ok;      label = "API key from environment"
        case (false, false): kind = .warning; label = "API key missing"
        }
        return SettingsStatusIcon(kind: kind, accessibilityLabel: label)
    }

    private func title(keychainPresent: Bool, envValuePresent: Bool) -> String {
        switch (keychainPresent, envValuePresent) {
        case (true, true):   "Using Keychain (env var present, overridden)"
        case (true, false):  "Stored in Keychain"
        case (false, true):  "Using key from environment"
        case (false, false): "No API key configured"
        }
    }

    private static func envHasValue(_ name: String) -> Bool {
        !(ProcessInfo.processInfo.environment[name]?.isEmpty ?? true)
    }
}
