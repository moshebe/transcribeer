import SwiftUI

struct SettingsView: View {
    @Binding var config: AppConfig
    @State private var apiKey: String = ""
    @State private var modelCatalog = ModelCatalogService()

    var body: some View {
        TabView {
            Tab("Pipeline", systemImage: "bolt") {
                pipelineTab
            }
            Tab("Transcription", systemImage: "waveform") {
                transcriptionTab
            }
            Tab("Summarization", systemImage: "text.badge.checkmark") {
                summarizationTab
            }
            Tab("Prompts", systemImage: "text.bubble") {
                PromptsSettingsView()
            }
        }
        .frame(width: 640, height: 460)
        .onAppear {
            apiKey = KeychainHelper.getAPIKey(backend: config.llmBackend) ?? ""
        }
    }

    // MARK: - Pipeline

    private var pipelineTab: some View {
        Form {
            Section {
                Toggle("Transcribe after recording", isOn: Binding(
                    get: { config.pipelineMode != "record-only" },
                    set: { enabled in
                        config.pipelineMode = enabled ? "record+transcribe" : "record-only"
                        save()
                    }
                ))

                Toggle("Summarize after transcription", isOn: Binding(
                    get: { config.pipelineMode == "record+transcribe+summarize" },
                    set: { enabled in
                        config.pipelineMode = enabled ? "record+transcribe+summarize" : "record+transcribe"
                        save()
                    }
                ))
                .disabled(config.pipelineMode == "record-only")
            } header: {
                Text("Pipeline Steps")
            }

            Section {
                Toggle("Auto-record Zoom meetings", isOn: Binding(
                    get: { config.zoomAutoRecord },
                    set: { config.zoomAutoRecord = $0; save() }
                ))
                Stepper(
                    value: Binding(
                        get: { config.zoomAutoRecordDelay },
                        set: { config.zoomAutoRecordDelay = max(0, $0); save() }
                    ),
                    in: 0...60
                ) {
                    HStack {
                        Text("Countdown before recording")
                        Spacer()
                        Text("\(config.zoomAutoRecordDelay)s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .disabled(!config.zoomAutoRecord)
            } header: {
                Text("Zoom Integration")
            } footer: {
                Text("Start/stop recording automatically when a Zoom meeting starts/ends. "
                    + "A notification with a cancel button appears during the countdown.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    // MARK: - Transcription

    private var transcriptionTab: some View {
        Form {
            Section {
                modelPicker
            } header: {
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
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Models are downloaded on first use (~0.1–1.5 GB). Stored in ~/.transcribeer/models/.")
                    if let message = modelCatalog.lastError {
                        Text(message).foregroundStyle(.orange)
                    }
                }
                .foregroundStyle(.secondary)
            }

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
        .formStyle(.grouped)
        .padding(.top, 8)
        .task {
            // Make sure whatever the user has selected is visible in the list,
            // then refresh from the network. If refresh fails the pre-seeded
            // entry keeps the UI usable.
            modelCatalog.ensureEntry(for: AppConfig.canonicalWhisperModel(config.whisperModel))
            await modelCatalog.refresh()
            modelCatalog.ensureEntry(for: AppConfig.canonicalWhisperModel(config.whisperModel))
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

    @ViewBuilder
    private var modelPicker: some View {
        let selected = AppConfig.canonicalWhisperModel(config.whisperModel)
        Picker("Model", selection: Binding(
            get: { selected },
            set: { config.whisperModel = $0; save() }
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

    // MARK: - Summarization

    private var summarizationTab: some View {
        let backend = LLMBackend.from(config.llmBackend)

        return Form {
            Section {
                Picker("Backend", selection: Binding(
                    get: { LLMBackend.from(config.llmBackend) },
                    set: { newBackend in
                        config.llmBackend = newBackend.rawValue
                        apiKey = KeychainHelper.getAPIKey(backend: newBackend.rawValue) ?? ""
                        save()
                    }
                )) {
                    ForEach(LLMBackend.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                TextField("Model", text: Binding(
                    get: { config.llmModel },
                    set: { config.llmModel = $0 }
                ))
                .onSubmit { save() }

                authFields(for: backend)
            } header: {
                Text("LLM Configuration")
            }

            Section {
                Toggle("Ask for prompt profile on stop", isOn: Binding(
                    get: { config.promptOnStop },
                    set: { config.promptOnStop = $0; save() }
                ))
            } header: {
                Text("Prompts")
            } footer: {
                Text("Show a profile picker when you stop a recording.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func authFields(for backend: LLMBackend) -> some View {
        switch backend.auth {
        case .localEndpoint:
            TextField("Ollama host", text: Binding(
                get: { config.ollamaHost },
                set: { config.ollamaHost = $0 }
            ))
            .onSubmit { save() }
            OllamaHostStatus(host: config.ollamaHost)

        case .apiKey:
            SecureField("API key", text: $apiKey)
                .onSubmit {
                    guard !apiKey.isEmpty else { return }
                    KeychainHelper.setAPIKey(backend: backend.rawValue, key: apiKey)
                }
            APIKeyStatus(backend: backend, keychainKey: apiKey)

        case .gcloudADC:
            GCloudAuthStatus()
        }
    }

    private func save() {
        ConfigManager.save(config)
    }
}

/// One row in the Whisper model picker, rendering name + status badges.
///
/// Kept as its own view so the `Picker` can render it both as the collapsed
/// label and inside the menu without duplicating layout.
private struct ModelPickerRow: View {
    let entry: WhisperModelEntry

    var body: some View {
        HStack(spacing: 6) {
            Text(entry.displayName)
            if entry.isRecommendedDefault {
                Text("default").modifier(BadgeStyle(tint: .accentColor))
            }
            if entry.isDownloaded {
                Text("downloaded").modifier(BadgeStyle(tint: .green))
            }
            if entry.isDisabled {
                Text("unsupported").modifier(BadgeStyle(tint: .secondary))
            }
        }
    }
}

private struct BadgeStyle: ViewModifier {
    let tint: Color
    var font: Font = .caption2

    func body(content: Content) -> some View {
        content
            .font(font)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Live reachability check for the configured Ollama host.
///
/// Probes `GET <host>/api/version` whenever the host string changes (debounced
/// via `task(id:)`) and renders a status pill matching the API key one so the
/// Summarization tab has consistent UX across backends.
private struct OllamaHostStatus: View {
    let host: String

    enum Probe: Equatable {
        case checking
        case reachable(version: String?)
        case unreachable(reason: String)
        case invalidURL
    }

    @State private var probe: Probe = .checking

    var body: some View {
        HStack(spacing: 6) {
            StatusIcon(kind: iconKind, accessibilityLabel: iconAccessibilityLabel)
            Text(title).font(.caption)
            if let badge {
                Text(badge).modifier(BadgeStyle(tint: badgeTint, font: .caption.monospaced()))
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .task(id: host) { await runProbe() }
    }

    private var iconKind: StatusIcon.Kind {
        switch probe {
        case .checking: .loading
        case .reachable: .ok
        case .unreachable: .warning
        case .invalidURL: .error
        }
    }

    private var iconAccessibilityLabel: String {
        switch probe {
        case .checking: "Checking Ollama"
        case .reachable: "Ollama reachable"
        case .unreachable: "Ollama unreachable"
        case .invalidURL: "Invalid Ollama host URL"
        }
    }

    private var title: String {
        switch probe {
        case .checking: "Checking Ollama…"
        case .reachable: isLocalhost ? "Running locally" : "Reachable"
        case let .unreachable(reason): "Not reachable — \(reason)"
        case .invalidURL: "Invalid host URL"
        }
    }

    private var badge: String? {
        switch probe {
        case let .reachable(version?): "v\(version)"
        case .reachable: isLocalhost ? "localhost" : hostDisplay
        default: nil
        }
    }

    private var badgeTint: Color {
        switch probe {
        case .reachable: .green
        default: .secondary
        }
    }

    private var isLocalhost: Bool {
        guard let url = URL(string: host), let h = url.host else { return false }
        return h == "localhost" || h == "127.0.0.1" || h == "::1"
    }

    private var hostDisplay: String {
        URL(string: host)?.host ?? host
    }

    private func runProbe() async {
        probe = .checking
        guard let base = URL(string: host) else {
            probe = .invalidURL
            return
        }
        var request = URLRequest(url: base.appendingPathComponent("api/version"))
        request.timeoutInterval = 2

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                probe = .unreachable(reason: "no HTTP response")
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                probe = .unreachable(reason: "HTTP \(http.statusCode)")
                return
            }
            probe = .reachable(version: parseVersion(data))
        } catch let error as URLError {
            probe = .unreachable(reason: Self.describe(error))
        } catch {
            probe = .unreachable(reason: error.localizedDescription)
        }
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: "timed out"
        case .cannotConnectToHost: "connection refused"
        default: error.localizedDescription
        }
    }

    private func parseVersion(_ data: Data) -> String? {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["version"] as? String
    }
}

/// Shared status icon used by every Summarization-tab status row. Centralizing
/// the icon/colour mapping keeps the three status views visually consistent
/// and ensures every icon carries an explicit accessibility label.
private struct StatusIcon: View {
    enum Kind { case loading, ok, warning, error }

    let kind: Kind
    let accessibilityLabel: String

    var body: some View {
        Group {
            switch kind {
            case .loading:
                ProgressView().controlSize(.mini)
            case .ok:
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .error:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Status pill under the API key field showing whether the key is sourced
/// from the Keychain or from the shell environment.
///
/// Source of truth mirrors `SummarizationService.requireAPIKey` — Keychain wins
/// over the env var, so the UI labels them accordingly.
private struct APIKeyStatus: View {
    let backend: LLMBackend
    let keychainKey: String

    var body: some View {
        if let envVarName = backend.envVar {
            let envPresent = Self.envHasValue(envVarName)
            let kcPresent = !keychainKey.isEmpty
            HStack(spacing: 6) {
                icon(keychainPresent: kcPresent, envValuePresent: envPresent)
                Text(title(keychainPresent: kcPresent, envValuePresent: envPresent))
                    .font(.caption)
                if envPresent {
                    Text("$\(envVarName)")
                        .modifier(BadgeStyle(tint: .green, font: .caption.monospaced()))
                        .help("Detected in your login shell environment")
                }
                Spacer()
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private func icon(keychainPresent: Bool, envValuePresent: Bool) -> some View {
        let kind: StatusIcon.Kind
        let label: String
        switch (keychainPresent, envValuePresent) {
        case (true, _):      kind = .ok;      label = "API key stored in Keychain"
        case (false, true):  kind = .ok;      label = "API key from environment"
        case (false, false): kind = .warning; label = "API key missing"
        }
        return StatusIcon(kind: kind, accessibilityLabel: label)
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

/// Status view shown for Gemini: reads the local gcloud ADC configuration and
/// tells the user exactly what's missing so they can fix it without leaving
/// the app.
private struct GCloudAuthStatus: View {
    @State private var status: GCloudAuth.Status?
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let status {
                detail(for: status)
            }
        }
        .task { await refresh() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            StatusIcon(kind: iconKind, accessibilityLabel: headline)
            Text(headline).font(.caption).bold()
            Spacer()
            refreshButton
        }
    }

    @ViewBuilder
    private func detail(for status: GCloudAuth.Status) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let account = status.account {
                row(label: "Account", value: account, ok: true)
            } else if status.gcloudAvailable {
                row(label: "Account", value: "not signed in", ok: false)
            }
            if let project = status.project {
                row(label: "Project", value: project, ok: true)
            } else if status.gcloudAvailable {
                row(label: "Project", value: "not set", ok: false)
            }
            row(
                label: "ADC",
                value: status.hasADC ? "configured" : "missing",
                ok: status.hasADC
            )
        }
        .font(.caption)

        if !status.isReady {
            Text(remediation(for: status))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await refresh() }
        } label: {
            if refreshing {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .help("Re-read gcloud configuration")
        .accessibilityLabel("Refresh Google Cloud status")
        .disabled(refreshing)
    }

    private var iconKind: StatusIcon.Kind {
        guard let status else { return .loading }
        return status.isReady ? .ok : .warning
    }

    private var headline: String {
        guard let status else { return "Checking Google Cloud…" }
        if !status.gcloudAvailable { return "gcloud CLI not found" }
        return status.isReady ? "Signed in to Google Cloud" : "Google Cloud auth incomplete"
    }

    private func row(label: String, value: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).modifier(BadgeStyle(tint: ok ? .green : .orange, font: .caption.monospaced()))
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func remediation(for status: GCloudAuth.Status) -> String {
        guard status.gcloudAvailable else {
            return "Install via: brew install --cask google-cloud-sdk"
        }
        let steps = [
            (status.hasADC, "gcloud auth application-default login"),
            (status.project != nil, "gcloud config set project <your-project>"),
            (status.account != nil, "gcloud auth login"),
        ]
            .filter { !$0.0 }
            .map(\.1)
        return steps.isEmpty ? "" : "Run: " + steps.joined(separator: "  &&  ")
    }

    private func refresh() async {
        refreshing = true
        status = await GCloudAuth.status()
        refreshing = false
    }
}
