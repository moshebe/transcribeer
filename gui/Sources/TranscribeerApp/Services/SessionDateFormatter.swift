import Foundation

/// Formats the date/time line shown under each session's name in the sidebar.
///
/// Prefers an explicit recording window ("Jun 15 · 10:30 – 11:15") when it's
/// available — that's what lets users line a session up against a calendar
/// entry at a glance. Falls back to a plain timestamp + duration for legacy
/// sessions that predate the window being persisted.
enum SessionDateFormatter {
    /// User-facing summary line. Deterministic in `now` + `calendar` so tests
    /// don't drift across midnight or DST.
    static func sidebarLine(
        for session: Session,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent,
    ) -> String {
        if let started = session.startedAt, let ended = session.endedAt {
            return rangeLine(
                started: started,
                ended: ended,
                now: now,
                calendar: calendar,
                locale: locale,
            )
        }
        if let started = session.startedAt {
            // Recording still in progress, or a session whose end timestamp
            // never got persisted (e.g. crash after capture).
            return startOnlyLine(
                started: started,
                now: now,
                calendar: calendar,
                locale: locale,
            )
        }
        // Legacy sessions (incl. imported files): keep the old "date · duration"
        // layout verbatim so nothing regresses.
        let duration = session.duration
        if duration.isEmpty || duration == "—" {
            return session.formattedDate
        }
        return "\(session.formattedDate) · \(duration)"
    }

    private static func rangeLine(
        started: Date,
        ended: Date,
        now: Date,
        calendar: Calendar,
        locale: Locale,
    ) -> String {
        let startDate = dateLabel(started, now: now, calendar: calendar, locale: locale)
        let startTime = timeFormatter(locale: locale, calendar: calendar).string(from: started)
        let endTime = timeFormatter(locale: locale, calendar: calendar).string(from: ended)

        if calendar.isDate(started, inSameDayAs: ended) {
            return "\(startDate) · \(startTime)–\(endTime)"
        }
        // Meeting spanned midnight. Show both day labels so users don't
        // misread the end time as belonging to the start date.
        let endDate = dateLabel(ended, now: now, calendar: calendar, locale: locale)
        return "\(startDate) \(startTime) – \(endDate) \(endTime)"
    }

    private static func startOnlyLine(
        started: Date,
        now: Date,
        calendar: Calendar,
        locale: Locale,
    ) -> String {
        let dayLabel = dateLabel(started, now: now, calendar: calendar, locale: locale)
        let startTime = timeFormatter(locale: locale, calendar: calendar).string(from: started)
        return "\(dayLabel) · \(startTime)"
    }

    /// "Jun 15" if the date is in the current calendar year, else "Jun 15, 2024".
    /// Uses localized templates so EU locales get "15 Jun" automatically.
    private static func dateLabel(
        _ date: Date,
        now: Date,
        calendar: Calendar,
        locale: Locale,
    ) -> String {
        let sameYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: now)
        let template = sameYear ? "MMMd" : "MMMdyyyy"
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.locale = locale
        fmt.setLocalizedDateFormatFromTemplate(template)
        return fmt.string(from: date)
    }

    private static func timeFormatter(locale: Locale, calendar: Calendar) -> DateFormatter {
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.locale = locale
        fmt.setLocalizedDateFormatFromTemplate("jmm")
        return fmt
    }
}
