import Foundation

/// A bucket of sessions sharing a date-range label (e.g. "Today", "October",
/// "2024"). The sidebar renders one `Section` per group in the order these
/// are returned.
struct SessionGroup: Equatable {
    let title: String
    let sessions: [Session]
}

/// Groups sessions into sidebar date buckets:
/// Today → Yesterday → weekday names for the rest of the last 7 days →
/// one section per month ("June") within the current year → "Month YYYY"
/// for prior years. Empty buckets are omitted.
///
/// Pure, injectable `now` + calendar so tests can pin the reference date
/// without relying on the system clock.
enum SessionGrouper {
    static func group(
        _ sessions: [Session],
        now: Date,
        calendar: Calendar = .current,
    ) -> [SessionGroup] {
        guard !sessions.isEmpty else { return [] }

        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: today),
              let startOfYear = calendar.date(
                from: calendar.dateComponents([.year], from: today),
              )
        else { return [SessionGroup(title: "All", sessions: sessions)] }

        // Preserve sort order of the input (sessions arrive newest-first
        // from `SessionManager.listSessions`).
        var buckets: [(key: String, title: String, sessions: [Session])] = []
        var index: [String: Int] = [:]
        let weekdayFormatter = cachedFormatter("EEEE", calendar: calendar)
        let monthFormatter = cachedFormatter("LLLL", calendar: calendar)
        let monthYearFormatter = cachedFormatter("LLLL yyyy", calendar: calendar)

        for session in sessions {
            let sessionDay = calendar.startOfDay(for: session.date)
            let (key, title) = bucket(
                sessionDay: sessionDay,
                sessionDate: session.date,
                today: today,
                yesterday: yesterday,
                sevenDaysAgo: sevenDaysAgo,
                startOfYear: startOfYear,
                calendar: calendar,
                weekdayFormatter: weekdayFormatter,
                monthFormatter: monthFormatter,
                monthYearFormatter: monthYearFormatter,
            )
            if let existing = index[key] {
                buckets[existing].sessions.append(session)
            } else {
                index[key] = buckets.count
                buckets.append((key: key, title: title, sessions: [session]))
            }
        }

        return buckets.map { SessionGroup(title: $0.title, sessions: $0.sessions) }
    }

    // swiftlint:disable:next function_parameter_count
    private static func bucket(
        sessionDay: Date,
        sessionDate: Date,
        today: Date,
        yesterday: Date,
        sevenDaysAgo: Date,
        startOfYear: Date,
        calendar: Calendar,
        weekdayFormatter: DateFormatter,
        monthFormatter: DateFormatter,
        monthYearFormatter: DateFormatter,
    ) -> (key: String, title: String) {
        if sessionDay >= today { return ("today", "Today") }
        if sessionDay >= yesterday { return ("yesterday", "Yesterday") }
        if sessionDay >= sevenDaysAgo {
            // Within the trailing 7 days → one section per weekday. Key by
            // the absolute day so two "Monday"s from different weeks never
            // collide (in practice the 7-day window can’t include two of
            // the same weekday, but the key stays correct regardless).
            let dayKey = Int(sessionDay.timeIntervalSince1970)
            return ("day-\(dayKey)", weekdayFormatter.string(from: sessionDate))
        }
        if sessionDay >= startOfYear {
            // Same calendar year, older than the 7-day window → one bucket
            // per month ("June", "May", ...).
            let month = calendar.component(.month, from: sessionDate)
            return ("m-\(month)", monthFormatter.string(from: sessionDate))
        }
        // Prior year: one bucket per "Month YYYY" so a long history doesn’t
        // collapse into a single "2023" lump.
        let comps = calendar.dateComponents([.year, .month], from: sessionDate)
        let year = comps.year ?? 0
        let month = comps.month ?? 0
        return ("y-\(year)-m-\(month)", monthYearFormatter.string(from: sessionDate))
    }

    private static func cachedFormatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.locale = calendar.locale ?? .current
        fmt.setLocalizedDateFormatFromTemplate(format)
        return fmt
    }
}
