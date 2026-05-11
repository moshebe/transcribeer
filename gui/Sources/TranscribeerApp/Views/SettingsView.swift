import SwiftUI

struct SettingsView: View {
    @Binding var config: AppConfig
    @State private var apiKey: String = ""
    @State private var transcriptionAPIKey: String = ""

    var body: some View {
        TabView {
            Tab("Pipeline", systemImage: "bolt") {
                pipelineTab
            }
            Tab("Audio", systemImage: "speaker.wave.2") {
                AudioSettingsView(config: $config)
            }
            Tab("Transcription", systemImage: "waveform") {
                TranscriptionSettingsView(
                    config: $config,
                    apiKey: $transcriptionAPIKey,
                    save: save,
                    reloadAPIKey: reloadTranscriptionKey
                )
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
            reloadTranscriptionKey()
        }
    }

    private func reloadTranscriptionKey() {
        let backend = TranscriptionBackend.from(config.transcriptionBackend)
        transcriptionAPIKey = backend.usesAPIKey
            ? (KeychainHelper.getAPIKey(backend: backend.keychainKey) ?? "")
            : ""
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
                Toggle("Auto-record meetings", isOn: Binding(
                    get: { config.meetingAutoRecord },
                    set: { config.meetingAutoRecord = $0; save() }
                ))
                Stepper(
                    value: Binding(
                        get: { config.meetingAutoRecordDelay },
                        set: { config.meetingAutoRecordDelay = max(0, $0); save() }
                    ),
                    in: 0...60
                ) {
                    HStack {
                        Text("Countdown before recording")
                        Spacer()
                        Text("\(config.meetingAutoRecordDelay)s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .disabled(!config.meetingAutoRecord)
            } header: {
                Text("Meeting Integration")
            } footer: {
                Text("Start/stop recording automatically when a meeting starts/ends. "
                    + "Detected from microphone + camera activity paired with a known meeting app. "
                    + "A notification with a cancel button appears during the countdown.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(MeetingDetector.defaultMeetingApps, id: \.bundleID) { app in
                    Toggle(app.displayName, isOn: Binding(
                        get: { config.meetingAutoRecordApps.contains(app.bundleID) },
                        set: { enabled in
                            if enabled {
                                config.meetingAutoRecordApps.insert(app.bundleID)
                            } else {
                                config.meetingAutoRecordApps.remove(app.bundleID)
                            }
                            save()
                        }
                    ))
                    .disabled(!config.meetingAutoRecord)
                }
            } header: {
                Text("Auto-Record Apps")
            } footer: {
                Text("Only the selected apps trigger auto-record when a meeting is detected. "
                    + "Unchecked apps still post a notification so you can start recording manually.")
                    .foregroundStyle(.secondary)
            }

            ScheduledTranscriptionSection(config: $config, save: save)

            Section {
                Toggle("Enrich Zoom meetings", isOn: Binding(
                    get: { config.zoomEnricherEnabled },
                    set: { config.zoomEnricherEnabled = $0; save() },
                ))
                Stepper(
                    value: Binding(
                        get: { config.maxMeetingParticipants },
                        set: { config.maxMeetingParticipants = max(0, $0); save() },
                    ),
                    in: 0...200,
                ) {
                    HStack {
                        Text("Skip when more than")
                        Spacer()
                        Text("\(config.maxMeetingParticipants) participants")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .disabled(!config.zoomEnricherEnabled)
            } header: {
                Text("Zoom Enricher")
            } footer: {
                Text("Reads the meeting topic and participant list from the Zoom app via "
                    + "the macOS Accessibility API while a recording is in progress. "
                    + "Participant names are only captured while you have Zoom's participants "
                    + "side panel open. Large meetings above the threshold are skipped to keep "
                    + "the session metadata focused on speakers.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
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
            SettingsStatusIcon(kind: iconKind, accessibilityLabel: iconAccessibilityLabel)
            Text(title).font(.caption)
            if let badge {
                Text(badge).modifier(SettingsBadgeStyle(tint: badgeTint, font: .caption.monospaced()))
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .task(id: host) { await runProbe() }
    }

    private var iconKind: SettingsStatusIcon.Kind {
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
                        .modifier(SettingsBadgeStyle(tint: .green, font: .caption.monospaced()))
                        .help("Detected in your login shell environment")
                }
                Spacer()
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
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
            SettingsStatusIcon(kind: iconKind, accessibilityLabel: headline)
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

    private var iconKind: SettingsStatusIcon.Kind {
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
            Text(value).modifier(SettingsBadgeStyle(tint: ok ? .green : .orange, font: .caption.monospaced()))
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
