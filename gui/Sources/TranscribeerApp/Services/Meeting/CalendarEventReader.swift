import EventKit
import Foundation
import os

/// Reads events from the macOS calendar store (Calendar.app accounts, such as
/// Google or iCloud) and maps them to plain `CalendarEvent` values. No match
/// logic lives here: see `CalendarEventMatcher`.
actor CalendarEventReader {
    static let shared = CalendarEventReader()

    private let store = EKEventStore()
    private let logger = Logger(subsystem: "com.transcribeer", category: "calendar-reader")

    nonisolated static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Ask for full calendar access. Returns the resulting state; macOS shows
    /// the prompt only once, later calls return the stored answer.
    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            logger.error("calendar access request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Events that intersect `window`, from calendars whose title contains one
    /// of `calendarNames` (case-insensitive). Empty `calendarNames` = all.
    func events(in window: DateInterval, calendarNames: [String]) -> [CalendarEvent] {
        guard Self.isAuthorized else { return [] }
        let calendars = store.calendars(for: .event).filter { calendar in
            calendarNames.isEmpty || calendarNames.contains { calendar.title.localizedCaseInsensitiveContains($0) }
        }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: calendars)
        return store.events(matching: predicate).map(Self.makeEvent)
    }

    // MARK: - Mapping

    private static func makeEvent(_ event: EKEvent) -> CalendarEvent {
        let participants = event.attendees ?? []
        let me = participants.first(where: \.isCurrentUser)
        let selfStatus: CalendarEvent.ResponseStatus = if let me {
            status(me.participantStatus)
        } else {
            // No attendee entry for the user: their own event, or one with no guests.
            .accepted
        }
        return CalendarEvent(
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            calendarTitle: event.calendar?.title ?? "",
            externalID: event.calendarItemExternalIdentifier,
            organizerEmail: event.organizer.flatMap { email(fromParticipantURL: $0.url) },
            selfStatus: selfStatus,
            attendees: participants
                .filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
                .map { participant in
                    CalendarEvent.Attendee(
                        name: participant.name,
                        email: email(fromParticipantURL: participant.url),
                        status: status(participant.participantStatus),
                    )
                },
        )
    }

    static func status(_ status: EKParticipantStatus) -> CalendarEvent.ResponseStatus {
        switch status {
        case .accepted, .delegated, .completed, .inProcess: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .pending: .pending
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    /// EventKit gives each participant a `mailto:` URL. Anything else (for
    /// example a `urn:` ID) has no usable email.
    static func email(fromParticipantURL url: URL) -> String? {
        let raw = url.absoluteString
        guard raw.lowercased().hasPrefix("mailto:") else { return nil }
        let address = String(raw.dropFirst("mailto:".count)).removingPercentEncoding ?? ""
        return address.isEmpty ? nil : address.lowercased()
    }
}
