import Foundation
import Testing
@testable import TranscribeerApp

struct SessionGrouperTests {
    // MARK: - Fixtures

    private static let referenceDate: Date = {
        var comps = DateComponents()
        comps.year = 2025
        comps.month = 6
        comps.day = 15
        comps.hour = 12
        return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
    }()

    private static var gregorian: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    /// Build a Session fixture whose only interesting field is `date`.
    private static func session(daysAgo: Int, id: String? = nil) -> Session {
        let date = gregorian.date(byAdding: .day, value: -daysAgo, to: referenceDate)
            ?? referenceDate
        return makeSession(id: id ?? "s-\(daysAgo)", date: date)
    }

    private static func session(on date: Date, id: String) -> Session {
        makeSession(id: id, date: date)
    }

    private static func makeSession(id: String, date: Date) -> Session {
        Session(
            id: id,
            path: URL(fileURLWithPath: "/tmp/\(id)"),
            name: id,
            isUntitled: false,
            date: date,
            formattedDate: "",
            duration: "",
            snippet: "",
            language: nil,
            hasAudio: false,
            hasTranscript: false,
            hasSummary: false,
            startedAt: nil,
            endedAt: nil,
        )
    }

    // MARK: - Tests

    @Test("Empty input produces no groups")
    func emptyInput() {
        let groups = SessionGrouper.group([], now: Self.referenceDate, calendar: Self.gregorian)
        #expect(groups.isEmpty)
    }

    @Test("Today and Yesterday buckets split at midnight")
    func todayYesterday() {
        let sessions = [
            Self.session(daysAgo: 0),
            Self.session(daysAgo: 1),
        ]
        let groups = SessionGrouper.group(
            sessions,
            now: Self.referenceDate,
            calendar: Self.gregorian,
        )
        #expect(groups.map(\.title) == ["Today", "Yesterday"])
    }

    @Test("Days inside the 7-day window render as weekday names")
    func weekdayBucketsWithinSevenDays() {
        // referenceDate = Sun June 15 2025.
        // 3 days ago = Thu June 12; 5 days ago = Tue June 10.
        let sessions = [
            Self.session(daysAgo: 3),
            Self.session(daysAgo: 5),
        ]
        let groups = SessionGrouper.group(
            sessions,
            now: Self.referenceDate,
            calendar: Self.gregorian,
        )
        #expect(groups.map(\.title) == ["Thursday", "Tuesday"])
    }

    @Test("Days older than 7 but in current year bucket by month name")
    func sameYearOlderBucketsByMonth() {
        // referenceDate = June 15 2025; 10 days ago = June 5 (still in June).
        // Add a May entry so we prove we get two distinct month buckets.
        let sessions = [
            Self.session(daysAgo: 10, id: "early-june"),
            Self.session(daysAgo: 40, id: "early-may"),
        ]
        let groups = SessionGrouper.group(
            sessions,
            now: Self.referenceDate,
            calendar: Self.gregorian,
        )
        #expect(groups.map(\.title) == ["June", "May"])
    }

    @Test("Older-in-same-year single session picks up the month name")
    func monthBucketSameYear() {
        // referenceDate = June 15 2025; pick February 2025 (well outside the
        // 7-day window).
        var comps = DateComponents()
        comps.year = 2025
        comps.month = 2
        comps.day = 10
        let date = Self.gregorian.date(from: comps) ?? Self.referenceDate
        let groups = SessionGrouper.group(
            [Self.session(on: date, id: "feb")],
            now: Self.referenceDate,
            calendar: Self.gregorian,
        )
        #expect(groups.count == 1)
        #expect(groups[0].title == "February")
    }

    @Test("Prior-year sessions bucket by \"Month YYYY\"")
    func monthYearBucketPriorYear() {
        var comps = DateComponents()
        comps.year = 2023
        comps.month = 11
        comps.day = 4
        let date = Self.gregorian.date(from: comps) ?? Self.referenceDate
        let groups = SessionGrouper.group(
            [Self.session(on: date, id: "nov23")],
            now: Self.referenceDate,
            calendar: Self.gregorian,
        )
        #expect(groups.count == 1)
        #expect(groups[0].title == "November 2023")
    }

    @Test("Group order follows Today → Yesterday → weekday → month → year")
    func groupOrdering() {
        // Inputs intentionally shuffled to prove order is driven by the
        // first appearance of each bucket's date range, not input order.
        let older2023: Session = {
            var comps = DateComponents()
            comps.year = 2023
            comps.month = 5
            comps.day = 1
            let date = Self.gregorian.date(from: comps) ?? Self.referenceDate
            return Self.session(on: date, id: "older")
        }()
        // referenceDate = Sun June 15 2025. 3 days ago = Thu June 12.
        let sessions = [
            Self.session(daysAgo: 40, id: "d40"),    // May 6 2025 → "May"
            Self.session(daysAgo: 0, id: "d0"),       // "Today"
            older2023,                                 // "May 2023"
            Self.session(daysAgo: 1, id: "d1"),       // "Yesterday"
            Self.session(daysAgo: 3, id: "d3"),       // "Thursday"
        ]
        let groups = SessionGrouper.group(
            sessions,
            now: Self.referenceDate,
            calendar: Self.gregorian,
        )
        #expect(groups.map(\.title) == [
            "May",
            "Today",
            "May 2023",
            "Yesterday",
            "Thursday",
        ])
    }

    @Test("Sessions within a group keep their input order")
    func preservesOrderWithinBucket() {
        let sessions = [
            Self.session(daysAgo: 0, id: "a"),
            Self.session(daysAgo: 0, id: "b"),
            Self.session(daysAgo: 0, id: "c"),
        ]
        let groups = SessionGrouper.group(
            sessions,
            now: Self.referenceDate,
            calendar: Self.gregorian,
        )
        #expect(groups.count == 1)
        #expect(groups[0].sessions.map(\.id) == ["a", "b", "c"])
    }
}
