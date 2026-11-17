import Foundation

/// Picks the calendar event a recording belongs to. Pure logic over plain
/// `CalendarEvent` values, so it is tested without EventKit.
///
/// Rules:
/// - Drop all-day events, events the user declined and, when
///   `requireAttendees` is set, events with no other attendees (focus blocks,
///   personal reminders).
/// - Score each remaining event by how many seconds it overlaps the recording.
///   A recording still in progress (no `end`) uses a short window of
///   `inProgressWindow` from its start, so a meeting that is about to end
///   loses to the one that is about to begin, and two meetings that both run
///   past the window tie.
/// - Highest overlap wins. On a tie (double booking), prefer an event the user
///   accepted, then the event with fewer attendees (a 1:1 over a forum). If it
///   is still a tie, return `nil`: never guess.
enum CalendarEventMatcher {
    static let inProgressWindow: TimeInterval = 10 * 60

    /// The recording window to score against, and to read events for (the
    /// EventKit predicate returns every event that intersects it).
    static func recordingWindow(start: Date, end: Date?) -> DateInterval {
        DateInterval(start: start, end: max(end ?? start.addingTimeInterval(inProgressWindow), start))
    }

    static func bestMatch(
        _ events: [CalendarEvent],
        start: Date,
        end: Date?,
        requireAttendees: Bool = true,
    ) -> CalendarEvent? {
        let recording = recordingWindow(start: start, end: end)
        let scored = events
            .filter { isEligible($0, requireAttendees: requireAttendees) }
            .map { (event: $0, overlap: overlap($0, recording)) }
            .filter { $0.overlap > 0 }
        guard let best = scored.map(\.overlap).max() else { return nil }

        return breakTie(scored.filter { $0.overlap == best }.map(\.event))
    }

    private static func breakTie(_ tied: [CalendarEvent]) -> CalendarEvent? {
        guard tied.count > 1 else { return tied.first }
        let accepted = tied.filter { $0.selfStatus == .accepted }
        let pool = accepted.isEmpty ? tied : accepted
        guard pool.count > 1 else { return pool.first }
        guard let fewest = pool.map(\.attendees.count).min() else { return nil }
        let smallest = pool.filter { $0.attendees.count == fewest }
        return smallest.count == 1 ? smallest.first : nil
    }

    static func isEligible(_ event: CalendarEvent, requireAttendees: Bool) -> Bool {
        guard !event.isAllDay, event.selfStatus != .declined, event.end > event.start else { return false }
        return !requireAttendees || !event.attendees.isEmpty
    }

    private static func overlap(_ event: CalendarEvent, _ recording: DateInterval) -> TimeInterval {
        let start = max(event.start, recording.start)
        let end = min(event.end, recording.end)
        return max(0, end.timeIntervalSince(start))
    }
}
