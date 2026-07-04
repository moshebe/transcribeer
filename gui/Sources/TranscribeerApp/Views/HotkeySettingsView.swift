import AppKit
import SwiftUI

/// Settings view for the global "Open Transcribeer" hotkey (Track 4.2).
///
/// Shows the current binding, lets the user edit it as a plain string, and
/// surfaces an Accessibility permission warning when the permission is missing.
struct HotkeySettingsView: View {
    @Binding var config: AppConfig
    var save: () -> Void
    var applyHotkey: (AppConfig) -> Void

    @State private var probe = PermissionsProbe()
    @State private var isEditing = false
    @State private var editBuffer = ""

    var body: some View {
        Form {
            Section {
                hotkeyRow
            } header: {
                Text("Global Shortcuts")
            } footer: {
                Text("Press the hotkey from any app to bring Transcribeer forward.")
                    .foregroundStyle(.secondary)
            }

            if !probe.accessibilityGranted {
                accessibilityWarningSection
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .onAppear { probe.startPolling() }
        .onDisappear { probe.stopPolling() }
    }

    // MARK: - Hotkey row

    @ViewBuilder
    private var hotkeyRow: some View {
        HStack {
            Text("Open Transcribeer")
            Spacer()
            if isEditing {
                editingControls
            } else {
                displayBadge
                Button("Change") {
                    editBuffer = config.openAppHotkey
                    isEditing = true
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var displayBadge: some View {
        if config.openAppHotkey.isEmpty {
            Text("Disabled")
                .foregroundStyle(.secondary)
                .font(.callout)
        } else {
            let display = HotkeyDescriptor.parse(config.openAppHotkey)?.displayString
                ?? config.openAppHotkey
            Text(display)
                .modifier(SettingsBadgeStyle(tint: .accentColor, font: .callout.monospaced()))
        }
    }

    @ViewBuilder
    private var editingControls: some View {
        TextField("e.g. cmd+shift+t", text: $editBuffer)
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)
            .onSubmit { commitEdit() }
        Button("Save") { commitEdit() }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        Button("Cancel") {
            isEditing = false
            editBuffer = ""
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    // MARK: - Accessibility warning

    private var accessibilityWarningSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accessibility permission required")
                        .font(.callout)
                    Text("Global hotkeys require Accessibility access to work when "
                        + "Transcribeer is not the active app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Settings") {
                    AccessibilityGuard.openSystemSettings()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    // MARK: - Commit

    private func commitEdit() {
        isEditing = false
        let trimmed = editBuffer.trimmingCharacters(in: .whitespaces).lowercased()
        config.openAppHotkey = trimmed
        save()
        applyHotkey(config)
        editBuffer = ""
    }
}
