import SwiftUI
import TranscribeerCore

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
    var saveAPIKey: (String) -> Void
    var reloadAPIKey: () -> Void
    /// Optional — when provided, the RAM warning banner is reactive.
    var transcriptionService: TranscriptionService?

    @State private var modelCatalog = ModelCatalogService()
    @State private var saveTask: Task<Void, Never>?

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
        .onDisappear { saveTask?.cancel() }
        .task {
            // Seed the catalog with all currently-selected models so pickers
            // are never empty before the network refresh completes.
            modelCatalog.ensureEntry(for: AppConfig.canonicalWhisperModel(config.whisperModel))
            modelCatalog.ensureEntry(for: AppConfig.canonicalWhisperModel(config.hebrewWhisperModel))
            modelCatalog.ensureEntry(for: AppConfig.canonicalWhisperModel(config.englishWhisperModel))
            await modelCatalog.refresh()
            modelCatalog.ensureEntry(for: AppConfig.canonicalWhisperModel(config.whisperModel))
            modelCatalog.ensureEntry(for: AppConfig.canonicalWhisperModel(config.hebrewWhisperModel))
            modelCatalog.ensureEntry(for: AppConfig.canonicalWhisperModel(config.englishWhisperModel))
        }
    }

    // MARK: - Backend picker

    private var backendSection: some View {
        Section {
            Picker("Backend", selection: Binding(
                get: { backend },
                set: { newBackend in
                    // Persist any unsaved key for the current backend before switching.
                    if !apiKey.isEmpty {
                        saveAPIKey(apiKey)
                    }
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
        hebrewModelSection
        englishModelSection
        otherLanguagesSection
        advancedSection
    }

    // MARK: Hebrew model section

    private var hebrewModelSection: some View {
        Section {
            CuratedModelPicker(
                label: "Hebrew model",
                language: "he",
                selection: Binding(
                    get: { config.hebrewWhisperModel },
                    set: { config.hebrewWhisperModel = $0; save() }
                ),
                downloader: HebrewModelDownloader()
            )
        } header: {
            Text("Hebrew")
        } footer: {
            Text("Used when Language is set to Hebrew. ivrit.ai CoreML models are downloaded separately.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: English model section

    private var englishModelSection: some View {
        Section {
            CuratedModelPicker(
                label: "English model",
                language: "en",
                selection: Binding(
                    get: { config.englishWhisperModel },
                    set: { config.englishWhisperModel = $0; save() }
                ),
                downloader: nil
            )
        } header: {
            Text("English")
        } footer: {
            Text("Used when Language is set to English. Downloaded from argmaxinc/whisperkit-coreml on first use.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Other languages section

    private var otherLanguagesSection: some View {
        Section {
            generalModelPicker
            ramWarningBanner
            idleUnloadStepper
        } header: {
            catalogHeader
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Used for Auto-detect and all other languages. Models are downloaded on first use (~0.1–3 GB).")
                if let message = modelCatalog.lastError {
                    Text(message).foregroundStyle(.orange)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Advanced section

    private var advancedSection: some View {
        Section {
            TextField("Custom model repo (optional)", text: Binding(
                get: { config.whisperModelRepo },
                set: { config.whisperModelRepo = $0; scheduleSave() },
            ))
            .onSubmit { saveTask?.cancel(); save() }
            if !config.whisperModelRepo.isEmpty {
                TextField("Model folder in repo", text: Binding(
                    get: { config.whisperModel },
                    set: { config.whisperModel = $0; scheduleSave() },
                ))
                .onSubmit { saveTask?.cancel(); save() }
                .help(
                    "The folder name inside the custom repo that WhisperKit should load. "
                    + "Must match a folder in the repo exactly "
                    + "(e.g. ivrit-ai_whisper-large-v3-turbo)."
                )
            }
        } header: {
            Text("Advanced")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Override the HuggingFace repo for the 'Other languages' model.")
                Text("Example: owner/ivrit-ai-whisper-large-v3-turbo-coreml")
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var ramWarningBanner: some View {
        if let warning = transcriptionService?.ramWarning {
            let availGB = String(format: "%.1f", Double(warning.available) / 1_000_000_000)
            let reqGB = String(format: "%.1f", Double(warning.required) / 1_000_000_000)
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Only \(availGB) GB available — this model needs ~\(reqGB) GB. Consider the turbo model.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var idleUnloadStepper: some View {
        Stepper(
            value: Binding(
                get: { config.idleUnloadMinutes },
                set: { config.idleUnloadMinutes = max(0, $0); save() },
            ),
            in: 0...120,
        ) {
            HStack {
                Text("Unload model after idle")
                Spacer()
                Text(config.idleUnloadMinutes == 0
                     ? "Never"
                     : "\(config.idleUnloadMinutes) min")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var catalogHeader: some View {
        HStack {
            Text("Other languages")
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

    private var generalModelPicker: some View {
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
                .onSubmit { saveTask?.cancel(); save() }
            SecureField("API key", text: $apiKey)
                .onSubmit {
                    guard !apiKey.isEmpty else { return }
                    saveTask?.cancel()
                    saveAPIKey(apiKey)
                }
                .onChange(of: apiKey) { _, newValue in
                    guard !newValue.isEmpty else { return }
                    scheduleAPIKeySave(newValue)
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
                scheduleSave()
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

    // MARK: - Debounced save

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await MainActor.run { save() }
        }
    }

    private func scheduleAPIKeySave(_ key: String) {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await MainActor.run { saveAPIKey(key) }
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

// MARK: - CuratedModelPicker

/// A Picker that presents a hardcoded curated list for a specific language,
/// plus a "Custom…" option that reveals a freeform text field.
///
/// `downloader` is non-nil for Hebrew entries so we can show an install badge.
struct CuratedModelPicker: View {
    let label: String
    let language: String
    @Binding var selection: String
    /// Passed in for Hebrew entries to check `isInstalled`; nil for English.
    var downloader: HebrewModelDownloader?

    @State private var isCustom: Bool = false

    private static let customSentinel = "__custom__"

    private var curatedEntries: [CuratedModelEntry] {
        ModelCatalogService.curatedEntries(language: language)
    }

    private var pickerSelection: Binding<String> {
        Binding(
            get: {
                let isKnown = curatedEntries.contains(where: { $0.id == selection })
                return isKnown ? selection : Self.customSentinel
            },
            set: { newValue in
                if newValue == Self.customSentinel {
                    isCustom = true
                } else {
                    isCustom = false
                    selection = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(label, selection: pickerSelection) {
                ForEach(curatedEntries) { entry in
                    CuratedModelRow(entry: entry, downloader: downloader).tag(entry.id)
                }
                Divider()
                Text("Custom…").tag(Self.customSentinel)
            }
            .pickerStyle(.menu)
            .onAppear {
                let isKnown = curatedEntries.contains(where: { $0.id == selection })
                isCustom = !isKnown && !selection.isEmpty
            }

            if isCustom {
                TextField("Model ID (e.g. owner/my-model)", text: $selection)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
            }
        }
    }
}

// MARK: - CuratedModelRow

/// A picker row for a curated model showing display name, size, and install status.
struct CuratedModelRow: View {
    let entry: CuratedModelEntry
    var downloader: HebrewModelDownloader?

    private var manifestEntry: ModelManifestEntry? {
        ModelManifest.all.first(where: { $0.id == entry.id })
    }

    private var isInstalled: Bool {
        guard let dl = downloader, let manifest = manifestEntry else { return false }
        return dl.isInstalled(manifest)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.displayName)
            Text(String(format: "%.1f GB", entry.sizeGB))
                .modifier(SettingsBadgeStyle(tint: .secondary))
            if entry.isRecommended {
                Text("recommended").modifier(SettingsBadgeStyle(tint: .accentColor))
            }
            if isInstalled {
                Text("installed").modifier(SettingsBadgeStyle(tint: .green))
            }
        }
    }
}
