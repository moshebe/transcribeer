import Foundation
import Testing
@testable import TranscribeerApp

struct SessionDateFormatterTests {
    // MARK: - Fixtures

    private static var gregorian: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    /// `en_GB` produces deterministic "d MMM" + 24h "HH:mm" output across
    /// macOS versions, so these tests can pin exact strings without being
    /// brittle about locale data churn.
    private static let locale = Locale(identifier: "en_GB")

    private static let now: Date = date(year: 2025, month: 6, day: 15, hour: 12)

    private static func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
    ) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        return gregorian.date(from: comps) ?? Date()
    }

    /// Session fixture that lets each test override just the recording-window
    /// fields and legacy fallback values.
    private static func session(
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        formattedDate: String = "Jan 1, 2000 00:00",
        duration: String = "",
    ) -> Session {
        Session(
            id: "x",
            path: URL(fileURLWithPath: "/tmp/x"),
            name: "x",
            isUntitled: false,
            date: startedAt ?? now,
            formattedDate: formattedDate,
            duration: duration,
            snippet: "",
            language: nil,
            hasAudio: false,
            hasTranscript: false,
            hasSummary: false,
            startedAt: startedAt,
            endedAt: endedAt,
        )
    }

    private static func format(_ session: Session) -> String {
        SessionDateFormatter.sidebarLine(
            for: session,
            now: now,
            calendar: gregorian,
            locale: locale,
        )
    }

    // MARK: - Tests

    @Test("Same-day meeting renders as date · start–end in current year")
    func sameDayMeetingCurrentYear() {
        let started = Self.date(year: 2025, month: 6, day: 15, hour: 10, minute: 30)
        let ended = Self.date(year: 2025, month: 6, day: 15, hour: 11, minute: 15)
        let line = Self.format(Self.session(startedAt: started, endedAt: ended))
        #expect(line == "15 Jun · 10:30–11:15")
    }

    @Test("Prior-year meeting includes the year")
    func sameDayMeetingPriorYear() {
        let started = Self.date(year: 2024, month: 11, day: 3, hour: 9, minute: 0)
        let ended = Self.date(year: 2024, month: 11, day: 3, hour: 9, minute: 45)
        let line = Self.format(Self.session(startedAt: started, endedAt: ended))
        #expect(line == "3 Nov 2024 · 09:00–09:45")
    }

    @Test("Meeting across midnight shows both day labels")
    func meetingAcrossMidnight() {
        let started = Self.date(year: 2025, month: 6, day: 14, hour: 23, minute: 30)
        let ended = Self.date(year: 2025, month: 6, day: 15, hour: 0, minute: 15)
        let line = Self.format(Self.session(startedAt: started, endedAt: ended))
        #expect(line == "14 Jun 23:30 – 15 Jun 00:15")
    }

    @Test("Only startedAt present (e.g. recording in progress) renders date · time")
    func startOnly() {
        let started = Self.date(year: 2025, month: 6, day: 15, hour: 8, minute: 5)
        let line = Self.format(Self.session(startedAt: started, endedAt: nil))
        #expect(line == "15 Jun · 08:05")
    }

    @Test("Legacy session with duration falls back to formattedDate · duration")
    func legacyWithDuration() {
        let session = Self.session(
            startedAt: nil,
            endedAt: nil,
            formattedDate: "Jan 4, 2024 10:30",
            duration: "0:45",
        )
        #expect(Self.format(session) == "Jan 4, 2024 10:30 · 0:45")
    }

    @Test("Legacy session without duration shows only formattedDate")
    func legacyNoDuration() {
        let session = Self.session(
            startedAt: nil,
            endedAt: nil,
            formattedDate: "Jan 4, 2024 10:30",
            duration: "—",
        )
        #expect(Self.format(session) == "Jan 4, 2024 10:30")
    }
}
