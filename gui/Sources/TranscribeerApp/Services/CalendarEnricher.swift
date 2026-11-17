import Foundation

/// Matches a session to a calendar event and records the result in
/// `meta.json`: the event itself, and the event title as the session name
/// (subject to `SessionNameSource` precedence).
///
/// The events source is injected so tests run without EventKit.
enum CalendarEnricher {
    /// Returns `nil` when the calendar cannot be read (no access).
    typealias EventsSource = @Sendable (DateInterval) async -> [CalendarEvent]?

    static func eventsSource(for config: AppConfig) -> EventsSource {
        let names = config.calendarNames
        return { window in await CalendarEventReader.shared.events(in: window, calendarNames: names) }
    }

    /// Returns a line for the session's `run.log`, or `nil` when the enricher
    /// is off. Never throws: enrichment is a side effect, not a pipeline step.
    @discardableResult
    static func enrich(
        session: URL,
        start: Date,
        end: Date?,
        stage: CalendarMatchStage,
        config: AppConfig,
        events: EventsSource? = nil,
    ) async -> String? {
        guard config.calendarEnricherEnabled else { return nil }
        let source = events ?? eventsSource(for: config)
        guard let candidates = await source(CalendarEventMatcher.recordingWindow(start: start, end: end)) else {
            return "calendar(\(stage.rawValue)): skipped, no calendar access"
        }
        // The stop match is authoritative; a slow start query must not overwrite it.
        if stage == .start, SessionManager.readMeta(session)["endedAt"] != nil {
            return "calendar(start): skipped, recording already stopped"
        }
        guard let match = CalendarEventMatcher.bestMatch(candidates, start: start, end: end) else {
            // A full-window match is authoritative: drop a start-time guess it does not confirm.
            let cleared = stage != .start && SessionManager.clearCalendarMatch(session)
            return "calendar(\(stage.rawValue)): no match in \(candidates.count) event(s)"
                + (cleared ? ", cleared earlier match" : "")
        }
        SessionManager.setCalendarEvent(session, match, stage: stage)
        let renamed = !match.title.isEmpty
            && SessionManager.setAutomaticName(session, match.title, source: .calendar)
        return "calendar(\(stage.rawValue)): matched \"\(match.title)\" "
            + "attendees=\(match.attendees.count) renamed=\(renamed)"
    }
}
