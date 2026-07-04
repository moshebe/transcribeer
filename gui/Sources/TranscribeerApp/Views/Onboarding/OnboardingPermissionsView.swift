import SwiftUI

struct OnboardingPermissionsView: View {
    let probe: PermissionsProbe

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                Section {
                    permissionCard(
                        icon: "mic.fill",
                        title: "Microphone",
                        description: "Required to record your voice.",
                        granted: probe.microphoneGranted,
                        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                    )
                    permissionCard(
                        icon: "display",
                        title: "System Audio Recording",
                        description: "Required to capture meeting audio.",
                        granted: probe.screenRecordingGranted,
                        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    )
                    permissionCard(
                        icon: "accessibility",
                        title: "Accessibility",
                        description: "Required for the global keyboard shortcut.",
                        granted: probe.accessibilityGranted,
                        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    )
                } footer: {
                    Text("You'll be prompted automatically when a feature needs a permission.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { probe.startPolling() }
        .onDisappear { probe.stopPolling() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text("Grant permissions")
                .font(.title2)
                .fontWeight(.semibold)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Permission card

    private func permissionCard(
        icon: String,
        title: String,
        description: String,
        granted: Bool,
        settingsURL: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Granted")
            } else {
                Button("Grant") {
                    openSettings(settingsURL)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 4)
    }

    private func openSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
