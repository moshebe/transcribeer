import Foundation
import Testing
@testable import TranscribeerApp

/// Tests for the pure scheduling helpers on `ScheduledTranscriptionService`.
/// The worker loop itself isn't exercised here — it's `@MainActor`-bound and
/// drives an `AppConfig` provider closure; the helpers contain all the date
/// math and filtering rules worth verifying.
struct ScheduledTranscriptionServiceTests {
    // MARK: - Calendar fixture

    /// Fixed UTC calendar so dates in tests don't depend on the runner's
    /// local time zone. Production code uses `.current` — the algorithm is
    /// the same.
    private static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        // swiftlint:disable:next force_unwrapping
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// Build a `Date` from explicit UTC components — keeps assertions readable.
    private static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0,
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        // swiftlint:disable:next force_unwrapping
        return calendar.date(from: components)!
    }

    // MARK: - nextFireDate

    @Test("Same day in the future returns today's hour")
    func sameDayFuture() {
        let now = Self.date(2026, 4, 27, 1, 30)
        let fire = ScheduledTranscriptionService.nextFireDate(
            after: now,
            hour: 3,
            calendar: Self.calendar,
        )
        #expect(fire == Self.date(2026, 4, 27, 3, 0))
    }

    @Test("After today's hour rolls to tomorrow")
    func sameDayAlreadyPassed() {
        let now = Self.date(2026, 4, 27, 9, 0)
        let fire = ScheduledTranscriptionService.nextFireDate(
            after: now,
            hour: 3,
            calendar: Self.calendar,
        )
        #expect(fire == Self.date(2026, 4, 28, 3, 0))
    }

    @Test("Exactly at the boundary rolls to tomorrow")
    func exactlyAtBoundary() {
        let now = Self.date(2026, 4, 27, 3, 0)
        let fire = ScheduledTranscriptionService.nextFireDate(
            after: now,
            hour: 3,
            calendar: Self.calendar,
        )
        #expect(fire == Self.date(2026, 4, 28, 3, 0))
    }

    @Test("Out-of-range hours clamp into [0, 23]")
    func clampsHour() {
        let now = Self.date(2026, 4, 27, 12, 0)
        let high = ScheduledTranscriptionService.nextFireDate(
            after: now,
            hour: 99,
            calendar: Self.calendar,
        )
        #expect(high == Self.date(2026, 4, 27, 23, 0))

        let low = ScheduledTranscriptionService.nextFireDate(
            after: now,
            hour: -5,
            calendar: Self.calendar,
        )
        #expect(low == Self.date(2026, 4, 28, 0, 0))
    }

    // MARK: - sessionsToProcess

    private func session(
        id: String,
        date: Date,
        hasAudio: Bool = true,
        hasTranscript: Bool = false,
        hasSummary: Bool = false,
    ) -> Session {
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
            hasAudio: hasAudio,
            hasTranscript: hasTranscript,
            hasSummary: hasSummary,
            startedAt: date,
            endedAt: nil,
        )
    }

    @Test("Picks yesterday's sessions with audio missing transcript")
    func picksMissingTranscript() {
        let yesterday = Self.date(2026, 4, 26, 14, 0)
        let referenceDate = Self.date(2026, 4, 27, 3, 0)
        let result = ScheduledTranscriptionService.sessionsToProcess(
            sessions: [session(id: "a", date: yesterday)],
            referenceDate: referenceDate,
            calendar: Self.calendar,
        )
        #expect(result.map(\.id) == ["a"])
    }

    @Test("Picks yesterday's sessions with transcript missing summary")
    func picksMissingSummary() {
        let yesterday = Self.date(2026, 4, 26, 14, 0)
        let referenceDate = Self.date(2026, 4, 27, 3, 0)
        let result = ScheduledTranscriptionService.sessionsToProcess(
            sessions: [session(id: "a", date: yesterday, hasTranscript: true)],
            referenceDate: referenceDate,
            calendar: Self.calendar,
        )
        #expect(result.map(\.id) == ["a"])
    }

    @Test("Skips sessions with both transcript and summary")
    func skipsCompleted() {
        let yesterday = Self.date(2026, 4, 26, 14, 0)
        let referenceDate = Self.date(2026, 4, 27, 3, 0)
        let completed = session(
            id: "a",
            date: yesterday,
            hasTranscript: true,
            hasSummary: true,
        )
        let result = ScheduledTranscriptionService.sessionsToProcess(
            sessions: [completed],
            referenceDate: referenceDate,
            calendar: Self.calendar,
        )
        #expect(result.isEmpty)
    }

    @Test("Skips sessions without audio")
    func skipsAudioless() {
        let yesterday = Self.date(2026, 4, 26, 14, 0)
        let referenceDate = Self.date(2026, 4, 27, 3, 0)
        let result = ScheduledTranscriptionService.sessionsToProcess(
            sessions: [session(id: "a", date: yesterday, hasAudio: false)],
            referenceDate: referenceDate,
            calendar: Self.calendar,
        )
        #expect(result.isEmpty)
    }

    @Test("Skips today's and older sessions")
    func skipsOutOfRange() {
        let referenceDate = Self.date(2026, 4, 27, 3, 0)
        let today = Self.date(2026, 4, 27, 1, 0)
        let yesterday = Self.date(2026, 4, 26, 14, 0)
        let twoDaysAgo = Self.date(2026, 4, 25, 14, 0)

        let result = ScheduledTranscriptionService.sessionsToProcess(
            sessions: [
                session(id: "today", date: today),
                session(id: "yesterday", date: yesterday),
                session(id: "old", date: twoDaysAgo),
            ],
            referenceDate: referenceDate,
            calendar: Self.calendar,
        )
        #expect(result.map(\.id) == ["yesterday"])
    }

    @Test("Yesterday's midnight boundary is included")
    func includesMidnightStart() {
        let referenceDate = Self.date(2026, 4, 27, 3, 0)
        let yesterdayMidnight = Self.date(2026, 4, 26, 0, 0)
        let result = ScheduledTranscriptionService.sessionsToProcess(
            sessions: [session(id: "a", date: yesterdayMidnight)],
            referenceDate: referenceDate,
            calendar: Self.calendar,
        )
        #expect(result.map(\.id) == ["a"])
    }

    @Test("Today's midnight is excluded (boundary belongs to today)")
    func excludesTodayMidnight() {
        let referenceDate = Self.date(2026, 4, 27, 3, 0)
        let todayMidnight = Self.date(2026, 4, 27, 0, 0)
        let result = ScheduledTranscriptionService.sessionsToProcess(
            sessions: [session(id: "a", date: todayMidnight)],
            referenceDate: referenceDate,
            calendar: Self.calendar,
        )
        #expect(result.isEmpty)
    }
}
