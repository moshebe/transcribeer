import AppKit
import SwiftUI

/// Settings tab for post-pipeline integrations: Obsidian, clipboard, file export.
struct IntegrationsSettingsView: View {
    @Binding var config: AppConfig
    let save: () -> Void

    var body: some View {
        Form {
            // MARK: Obsidian
            Section {
                Toggle("Auto-import to Obsidian", isOn: Binding(
                    get: { config.integrations.obsidianEnabled },
                    set: { config.integrations.obsidianEnabled = $0; save() }
                ))

                HStack {
                    TextField("Vault path", text: Binding(
                        get: { config.integrations.obsidianVaultPath },
                        set: { config.integrations.obsidianVaultPath = $0; save() }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!config.integrations.obsidianEnabled)

                    Button("Choose vault…") {
                        chooseVaultPath()
                    }
                    .disabled(!config.integrations.obsidianEnabled)
                }
            } header: {
                Text("Obsidian")
            } footer: {
                Text("The Obsidian plugin polls your session folder and imports notes automatically. "
                    + "The vault path is validated when a recording finishes.")
                    .foregroundStyle(.secondary)
            }

            // MARK: Clipboard
            Section {
                Toggle("Copy summary to clipboard after recording", isOn: Binding(
                    get: { config.integrations.clipboardCopySummary },
                    set: { config.integrations.clipboardCopySummary = $0; save() }
                ))

                Toggle("Copy transcript to clipboard after recording", isOn: Binding(
                    get: { config.integrations.clipboardCopyTranscript },
                    set: { config.integrations.clipboardCopyTranscript = $0; save() }
                ))
            } header: {
                Text("Clipboard")
            } footer: {
                Text("Pastes the selected content into the system clipboard when the pipeline finishes. "
                    + "If both are enabled, the transcript overwrites the summary.")
                    .foregroundStyle(.secondary)
            }

            // MARK: File export
            Section {
                Toggle("Save SRT subtitle file", isOn: Binding(
                    get: { config.integrations.exportFormats.contains("srt") },
                    set: { enabled in
                        toggleFormat("srt", enabled: enabled)
                        save()
                    }
                ))

                Toggle("Save VTT subtitle file", isOn: Binding(
                    get: { config.integrations.exportFormats.contains("vtt") },
                    set: { enabled in
                        toggleFormat("vtt", enabled: enabled)
                        save()
                    }
                ))
            } header: {
                Text("File Export")
            } footer: {
                Text("Automatically writes subtitle files alongside the transcript when a recording finishes.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private func toggleFormat(_ format: String, enabled: Bool) {
        if enabled {
            if !config.integrations.exportFormats.contains(format) {
                config.integrations.exportFormats.append(format)
            }
        } else {
            config.integrations.exportFormats.removeAll { $0 == format }
        }
    }

    private func chooseVaultPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select your Obsidian vault folder"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        config.integrations.obsidianVaultPath = url.path
        save()
    }
}
