import AppKit
import SwiftUI

/// Pipeline-tab section for the calendar enricher. Turning it on asks for
/// calendar access; if access is denied the toggle turns back off and the
/// section links to System Settings.
struct CalendarEnricherSection: View {
    @Binding var config: AppConfig
    let save: () -> Void

    @State private var authorized = CalendarEventReader.isAuthorized
    @State private var calendarNamesText = ""
    /// The toggle's latest state, so a slow access request does not undo a later switch-off.
    @State private var wantsEnabled = false

    private static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
    )

    var body: some View {
        Section {
            Toggle("Match recordings to calendar events", isOn: Binding(
                get: { config.calendarEnricherEnabled },
                set: { setEnabled($0) },
            ))
            if config.calendarEnricherEnabled || !authorized {
                accessRow
            }
            TextField("Calendars", text: $calendarNamesText, prompt: Text("All calendars"))
                .onSubmit(saveCalendarNames)
                .disabled(!config.calendarEnricherEnabled)
        } header: {
            Text("Calendar Enricher")
        } footer: {
            Text("Finds the calendar event that overlaps each recording and saves its title and "
                + "attendees with the session. The event title becomes the session name unless "
                + "you named it yourself. Calendars: comma-separated names to search "
                + "(part of a name is enough); leave empty for all.")
                .foregroundStyle(.secondary)
        }
        .onAppear {
            authorized = CalendarEventReader.isAuthorized
            wantsEnabled = config.calendarEnricherEnabled
            calendarNamesText = config.calendarNames.joined(separator: ", ")
        }
        .onDisappear(perform: saveCalendarNames)
    }

    // MARK: - Access

    @ViewBuilder private var accessRow: some View {
        HStack {
            SettingsStatusIcon(
                kind: authorized ? .ok : .warning,
                accessibilityLabel: authorized ? "Calendar access granted" : "No calendar access",
            )
            Text(authorized ? "Calendar access granted" : "No calendar access")
            Spacer()
            if !authorized, let url = Self.privacySettingsURL {
                Button("Open System Settings") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private func setEnabled(_ enabled: Bool) {
        wantsEnabled = enabled
        guard enabled else {
            config.calendarEnricherEnabled = false
            save()
            return
        }
        Task { @MainActor in
            let granted = await CalendarEventReader.shared.requestAccess()
            authorized = granted
            guard wantsEnabled else { return }
            config.calendarEnricherEnabled = granted
            save()
        }
    }

    private func saveCalendarNames() {
        let names = calendarNamesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard names != config.calendarNames else { return }
        config.calendarNames = names
        save()
    }
}
