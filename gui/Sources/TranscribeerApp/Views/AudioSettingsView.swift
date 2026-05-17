import CaptureCore
import CoreAudio
import SwiftUI

/// Audio device selection, echo cancellation, and speaker label settings.
///
/// Auto-save debounces text-field edits (Self / Other labels) so typing
/// doesn't hammer the disk. Pickers and toggles save immediately.
struct AudioSettingsView: View {
    @Binding var config: AppConfig
    @State private var inputDevices: [(uid: String, name: String)] = []
    @State private var outputDevices: [(uid: String, name: String)] = []
    @State private var showAdvanced = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Picker("Input device", selection: Binding(
                    get: { config.audio.inputDeviceUID },
                    set: { newValue in
                        config.audio.inputDeviceUID = newValue
                        save()
                    }
                )) {
                    Text("System default").tag("")
                    ForEach(inputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                Picker("Output device", selection: Binding(
                    get: { config.audio.outputDeviceUID },
                    set: { newValue in
                        config.audio.outputDeviceUID = newValue
                        save()
                    }
                )) {
                    Text("System default").tag("")
                    ForEach(outputDevices, id: \.uid) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                Toggle("Echo cancellation", isOn: Binding(
                    get: { config.audio.aec },
                    set: { newValue in
                        config.audio.aec = newValue
                        save()
                    }
                ))
            } header: {
                Text("Devices")
            } footer: {
                Text(
                    "Select non-default devices when you want to capture "
                        + "a specific microphone or route system audio through a particular output."
                )
                .foregroundStyle(.secondary)
            }

            Section {
                TextField("Self label", text: Binding(
                    get: { config.audio.selfLabel },
                    set: { newValue in
                        config.audio.selfLabel = newValue
                        scheduleSave()
                    }
                ))

                TextField("Other label", text: Binding(
                    get: { config.audio.otherLabel },
                    set: { newValue in
                        config.audio.otherLabel = newValue
                        scheduleSave()
                    }
                ))
            } header: {
                Text("Speaker Labels")
            } footer: {
                Text(
                    "These labels appear in the transcript to identify who spoke. "
                        + "Self = your microphone, Other = system audio."
                )
                .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(
                            "Run diarization on mic when multiple speakers share it",
                            isOn: Binding(
                                get: { config.audio.diarizeMicMultiuser },
                                set: { newValue in
                                    config.audio.diarizeMicMultiuser = newValue
                                    save()
                                }
                            )
                        )

                        if config.audio.diarizeMicMultiuser {
                            Stepper(
                                value: Binding(
                                    get: { config.numSpeakers },
                                    set: { newValue in
                                        config.numSpeakers = max(0, newValue)
                                        save()
                                    }
                                ),
                                in: 0...10
                            ) {
                                HStack {
                                    Text("Number of speakers")
                                    Spacer()
                                    Text(config.numSpeakers == 0 ? "Auto" : "\(config.numSpeakers)")
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .onAppear { refreshDevices() }
        .onDisappear { saveTask?.cancel() }
    }

    // MARK: - Device enumeration

    private func refreshDevices() {
        // Preserve the user's stored device selection even when the device is
        // currently disconnected. Append it as a "(disconnected)" entry so the
        // picker displays something meaningful and the user can intentionally
        // switch away.  `CaptureService.resolveMicDevice` already falls back
        // to the system default at record time when a UID doesn't resolve.
        inputDevices = Self.devices(
            from: AudioDevices.availableInputDevices(),
            storedUID: config.audio.inputDeviceUID
        )
        outputDevices = Self.devices(
            from: AudioDevices.availableOutputDevices(),
            storedUID: config.audio.outputDeviceUID
        )
    }

    private static func devices(
        from hardware: [(id: AudioDeviceID, name: String, uid: String)],
        storedUID: String
    ) -> [(uid: String, name: String)] {
        var list = hardware.map { (uid: $0.uid, name: $0.name) }
        if !storedUID.isEmpty, !list.contains(where: { $0.uid == storedUID }) {
            list.append((uid: storedUID, name: "\(storedUID) (disconnected)"))
        }
        return list
    }

    // MARK: - Save

    private func save() {
        ConfigManager.save(config)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await MainActor.run { save() }
        }
    }
}
