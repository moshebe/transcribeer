import Foundation

/// A calendar event as the calendar enricher sees it: a plain value read from
/// EventKit, used both as a match candidate and as the `calendar_event` entry
/// persisted in a session's `meta.json`.
///
/// `attendees` never includes the current user. Their own response lives in
/// `selfStatus`.
struct CalendarEvent: Equatable, Sendable {
    enum ResponseStatus: String, Sendable {
        case accepted, declined, tentative, pending, unknown
    }

    struct Attendee: Equatable, Sendable {
        let name: String?
        let email: String?
        let status: ResponseStatus
    }

    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String
    let externalID: String?
    let organizerEmail: String?
    let selfStatus: ResponseStatus
    let attendees: [Attendee]
}

/// When a session's calendar event was matched.
enum CalendarMatchStage: String, Sendable {
    /// Recording started; the match used the events in progress.
    case start
    /// Recording stopped; the match used the full recording window.
    case stop
    /// The user asked for a match from the history.
    case manual
}

// MARK: - meta.json encoding

extension CalendarEvent {
    func dict(matchedAt stage: CalendarMatchStage, using formatter: ISO8601DateFormatter) -> [String: Any] {
        var dict: [String: Any] = [
            "title": title,
            "start": formatter.string(from: start),
            "end": formatter.string(from: end),
            "calendar": calendarTitle,
            "self_status": selfStatus.rawValue,
            "attendees": attendees.map(\.dict),
            "matched_at": stage.rawValue,
        ]
        if isAllDay { dict["all_day"] = true }
        if let externalID { dict["external_id"] = externalID }
        if let organizerEmail { dict["organizer"] = organizerEmail }
        return dict
    }

    init?(dict: [String: Any], using formatter: ISO8601DateFormatter) {
        guard let title = dict["title"] as? String,
              let startRaw = dict["start"] as? String, let start = formatter.date(from: startRaw),
              let endRaw = dict["end"] as? String, let end = formatter.date(from: endRaw)
        else { return nil }
        self.init(
            title: title,
            start: start,
            end: end,
            isAllDay: dict["all_day"] as? Bool ?? false,
            calendarTitle: dict["calendar"] as? String ?? "",
            externalID: dict["external_id"] as? String,
            organizerEmail: dict["organizer"] as? String,
            selfStatus: (dict["self_status"] as? String).flatMap(ResponseStatus.init(rawValue:)) ?? .unknown,
            attendees: (dict["attendees"] as? [[String: Any]] ?? []).map(Attendee.init(dict:)),
        )
    }
}

extension CalendarEvent.Attendee {
    var dict: [String: Any] {
        var dict: [String: Any] = ["status": status.rawValue]
        if let name { dict["name"] = name }
        if let email { dict["email"] = email }
        return dict
    }

    init(dict: [String: Any]) {
        self.init(
            name: dict["name"] as? String,
            email: dict["email"] as? String,
            status: (dict["status"] as? String).flatMap(CalendarEvent.ResponseStatus.init(rawValue:)) ?? .unknown,
        )
    }
}
