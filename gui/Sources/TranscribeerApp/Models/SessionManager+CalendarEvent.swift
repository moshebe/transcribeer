import Foundation

/// Who set a session's name. Automatic sources never overwrite the user, and a
/// calendar title wins over a Zoom topic (a personal meeting room topic says
/// less than the event title).
enum SessionNameSource: String, Sendable {
    case user, calendar, zoom

    var rank: Int {
        switch self {
        case .user: 2
        case .calendar: 1
        case .zoom: 0
        }
    }
}

extension SessionManager {
    static let calendarEventKey = "calendar_event"

    /// Set an automatic name. Writes only when the session has no name, or
    /// when its current name came from an automatic source of the same or
    /// lower rank. A name with no recorded source predates `name_source` and
    /// counts as the user's.
    @discardableResult
    static func setAutomaticName(_ dir: URL, _ name: String, source: SessionNameSource) -> Bool {
        let meta = readMeta(dir)
        let current = meta["name"] as? String ?? ""
        guard shouldReplaceName(
            current: current,
            currentSource: (meta["name_source"] as? String).flatMap(SessionNameSource.init(rawValue:)),
            with: source,
        ) else { return false }
        setName(dir, name, source: source)
        return true
    }

    static func shouldReplaceName(
        current: String,
        currentSource: SessionNameSource?,
        with source: SessionNameSource,
    ) -> Bool {
        guard !current.isEmpty else { return true }
        guard let currentSource, currentSource != .user else { return false }
        return source.rank >= currentSource.rank
    }

    static func setCalendarEvent(_ dir: URL, _ event: CalendarEvent, stage: CalendarMatchStage) {
        var data = readMeta(dir)
        data[calendarEventKey] = event.dict(matchedAt: stage, using: isoFormatter)
        writeMeta(dir, data)
    }

    /// Remove a calendar match, and the name it set. A name from the user or
    /// Zoom stays. Returns whether anything was removed.
    @discardableResult
    static func clearCalendarMatch(_ dir: URL) -> Bool {
        var data = readMeta(dir)
        var changed = data.removeValue(forKey: calendarEventKey) != nil
        if data["name_source"] as? String == SessionNameSource.calendar.rawValue {
            data.removeValue(forKey: "name")
            data.removeValue(forKey: "name_source")
            changed = true
        }
        if changed { writeMeta(dir, data) }
        return changed
    }

    static func readCalendarEvent(_ dir: URL) -> CalendarEvent? {
        (readMeta(dir)[calendarEventKey] as? [String: Any])
            .flatMap { CalendarEvent(dict: $0, using: isoFormatter) }
    }
}
