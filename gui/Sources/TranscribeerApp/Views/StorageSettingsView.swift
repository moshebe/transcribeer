import SwiftUI

/// Settings tab for what happens to old recordings on this Mac.
struct StorageSettingsView: View {
    @Binding var config: AppConfig
    let save: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Clean up old recordings automatically", isOn: Binding(
                    get: { config.retention.enabled },
                    set: { config.retention.enabled = $0; save() }
                ))

                Stepper(
                    "After \(config.retention.days) day\(config.retention.days == 1 ? "" : "s")",
                    value: Binding(
                        get: { config.retention.days },
                        set: { config.retention.days = $0; save() }
                    ),
                    in: 1...365
                )
                .disabled(!config.retention.enabled)

                Toggle("Delete audio", isOn: Binding(
                    get: { config.retention.deleteAudio },
                    set: { config.retention.deleteAudio = $0; save() }
                ))
                .disabled(!config.retention.enabled)

                Toggle("Delete transcript", isOn: Binding(
                    get: { config.retention.deleteTranscript },
                    set: { config.retention.deleteTranscript = $0; save() }
                ))
                .disabled(!config.retention.enabled)
            } header: {
                Text("Retention")
            } footer: {
                Text("Old files are moved to the Trash. Summaries and notes are always kept. "
                    + "Audio is only removed once the recording has a transcript or summary, and a "
                    + "transcript only once it has a summary — an unprocessed recording is never touched. "
                    + "To keep a copy elsewhere first, turn on Integrations → Meeting Notes Folder & Backup.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
