import SwiftUI

/// Pipeline-tab section that toggles the nightly batch transcription job and
/// picks its fire hour. Persists immediately via the supplied `save` closure
/// so behaviour matches every other Settings toggle in the app.
struct ScheduledTranscriptionSection: View {
    @Binding var config: AppConfig
    let save: () -> Void

    var body: some View {
        Section {
            Toggle("Process yesterday's recordings overnight", isOn: Binding(
                get: { config.scheduledTranscriptionEnabled },
                set: { config.scheduledTranscriptionEnabled = $0; save() },
            ))
            Stepper(
                value: Binding(
                    get: { config.scheduledTranscriptionHour },
                    set: { newHour in
                        config.scheduledTranscriptionHour = max(0, min(23, newHour))
                        save()
                    },
                ),
                in: 0...23,
            ) {
                HStack {
                    Text("Run at")
                    Spacer()
                    Text(Self.formatHour(config.scheduledTranscriptionHour))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .disabled(!config.scheduledTranscriptionEnabled)
        } header: {
            Text("Scheduled Transcription")
        } footer: {
            Text("At the chosen local time each day, transcribe and "
                + "summarize all recordings started the previous day. "
                + "Skipped if a recording is in progress at fire time.")
                .foregroundStyle(.secondary)
        }
    }

    /// "03:00", "15:00" — 24-hour clock keeps the label compact and
    /// unambiguous regardless of the user's locale.
    static func formatHour(_ hour: Int) -> String {
        String(format: "%02d:00", max(0, min(23, hour)))
    }
}
