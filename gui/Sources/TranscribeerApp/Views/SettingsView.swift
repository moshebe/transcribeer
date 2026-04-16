import TranscribeerCore
import SwiftUI

struct SettingsView: View {
    @Binding var config: AppConfig
    @State private var apiKey: String = ""
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            pipelineTab
                .tabItem { Label("Pipeline", systemImage: "bolt") }
                .tag(0)

            transcriptionTab
                .tabItem { Label("Transcription", systemImage: "waveform") }
                .tag(1)

            summarizationTab
                .tabItem { Label("Summarization", systemImage: "text.badge.checkmark") }
                .tag(2)
        }
        .frame(width: 460, height: 360)
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
                        if enabled {
                            config.pipelineMode = "record+transcribe"
                        } else {
                            config.pipelineMode = "record-only"
                        }
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
            } header: {
                Text("Zoom Integration")
            } footer: {
                Text("Start/stop recording automatically when a Zoom meeting starts/ends.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    // MARK: - Transcription

    private static let whisperModels = [
        "base", "small", "medium", "large-v3", "large-v3-turbo",
    ]

    private var transcriptionTab: some View {
        Form {
            Section {
                Picker("Whisper model", selection: Binding(
                    get: { config.whisperModel },
                    set: { config.whisperModel = $0; save() }
                )) {
                    ForEach(Self.whisperModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("Models are downloaded on first use (~0.1–1.5 GB). Stored in ~/.transcribeer/models/.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Speaker detection", selection: Binding(
                    get: { config.diarization },
                    set: { config.diarization = $0; save() }
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
    }

    // MARK: - Summarization

    private var summarizationTab: some View {
        Form {
            Section {
                Picker("Backend", selection: Binding(
                    get: { config.llmBackend },
                    set: {
                        config.llmBackend = $0
                        apiKey = KeychainHelper.getAPIKey(backend: $0) ?? ""
                        save()
                    }
                )) {
                    Text("ollama").tag("ollama")
                    Text("openai").tag("openai")
                    Text("anthropic").tag("anthropic")
                }

                TextField("Model", text: Binding(
                    get: { config.llmModel },
                    set: { config.llmModel = $0 }
                ))
                .onSubmit { save() }

                if config.llmBackend == "ollama" {
                    TextField("Ollama host", text: Binding(
                        get: { config.ollamaHost },
                        set: { config.ollamaHost = $0 }
                    ))
                    .onSubmit { save() }
                }

                if config.llmBackend != "ollama" {
                    SecureField("API key", text: $apiKey)
                        .onSubmit {
                            if !apiKey.isEmpty {
                                KeychainHelper.setAPIKey(backend: config.llmBackend, key: apiKey)
                            }
                        }
                }
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

    private func save() {
        ConfigManager.save(config)
    }
}
