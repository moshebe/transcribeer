import Foundation
import Testing
@testable import TranscribeerApp

struct CalendarEventMatcherTests {
    static let base = Date(timeIntervalSince1970: 1_794_405_600) // 2026-11-11 16:00 +02:00

    static func at(_ minutes: Double) -> Date {
        base.addingTimeInterval(minutes * 60)
    }

    static func event(
        _ title: String,
        from start: Double,
        to end: Double,
        status: CalendarEvent.ResponseStatus = .accepted,
        attendees: Int = 1,
        allDay: Bool = false,
    ) -> CalendarEvent {
        CalendarEvent(
            title: title,
            start: at(start),
            end: at(end),
            isAllDay: allDay,
            calendarTitle: "work",
            externalID: title,
            organizerEmail: nil,
            selfStatus: status,
            attendees: (0..<attendees).map { index in
                CalendarEvent.Attendee(name: "P\(index)", email: "p\(index)@example.com", status: .accepted)
            },
        )
    }

    struct Case: CustomTestStringConvertible, Sendable {
        let label: String
        let events: [CalendarEvent]
        let start: Double
        let end: Double?
        let expected: String?
        var testDescription: String { label }
    }

    static let cases: [Case] = [
        Case(
            label: "back-to-back: largest overlap wins",
            events: [event("Tamir 1:1", from: 0, to: 30), event("Itay 1:1", from: 30, to: 55)],
            start: 6,
            end: 31,
            expected: "Tamir 1:1",
        ),
        Case(
            label: "back-to-back: later recording picks the second meeting",
            events: [event("Tamir 1:1", from: 0, to: 30), event("Itay 1:1", from: 30, to: 55)],
            start: 38,
            end: 61,
            expected: "Itay 1:1",
        ),
        Case(
            label: "in progress at start: the meeting about to begin beats the one about to end",
            events: [event("Tamir 1:1", from: 0, to: 30), event("Itay 1:1", from: 30, to: 55)],
            start: 29,
            end: nil,
            expected: "Itay 1:1",
        ),
        Case(
            label: "declined event is ignored",
            events: [event("Declined", from: 0, to: 60, status: .declined), event("Sync", from: 10, to: 20)],
            start: 0,
            end: 60,
            expected: "Sync",
        ),
        Case(
            label: "all-day event is ignored",
            events: [event("Offsite", from: -600, to: 840, allDay: true)],
            start: 0,
            end: 30,
            expected: nil,
        ),
        Case(
            label: "event with no other attendees is ignored",
            events: [event("Kids time", from: 0, to: 60, attendees: 0)],
            start: 0,
            end: 30,
            expected: nil,
        ),
        Case(
            label: "no overlap gives no match",
            events: [event("Later", from: 60, to: 90)],
            start: 0,
            end: 30,
            expected: nil,
        ),
        Case(
            label: "double booking: accepted event wins the tie",
            events: [event("Pending", from: 0, to: 30, status: .pending), event("Accepted", from: 0, to: 30)],
            start: 0,
            end: 30,
            expected: "Accepted",
        ),
        Case(
            label: "start 17 min into a 1:1, forum begins 13 min later (2026-11-17 regression)",
            events: [
                event("Or / Shirly - 1:1", from: 0, to: 30),
                event("AI forum", from: 30, to: 80, attendees: 53),
            ],
            start: 17,
            end: nil,
            expected: "Or / Shirly - 1:1",
        ),
        Case(
            label: "stop shortly after the next meeting begins (2026-11-17 regression)",
            events: [
                event("Or / Shirly - 1:1", from: 0, to: 30),
                event("AI forum", from: 30, to: 80, attendees: 53),
            ],
            start: 17,
            end: 33,
            expected: "Or / Shirly - 1:1",
        ),
        Case(
            label: "double booked at start: the smaller accepted meeting wins",
            events: [
                event("Forum", from: 0, to: 60, attendees: 54),
                event("1:1", from: 0, to: 30),
            ],
            start: 17,
            end: nil,
            expected: "1:1",
        ),
        Case(
            label: "tie with only unanswered events: fewer attendees wins",
            events: [
                event("Big", from: 0, to: 30, status: .pending, attendees: 8),
                event("Small", from: 0, to: 30, status: .pending, attendees: 2),
            ],
            start: 0,
            end: 30,
            expected: "Small",
        ),
        Case(
            label: "double booking with the same status gives no match",
            events: [event("A", from: 0, to: 30), event("B", from: 0, to: 30)],
            start: 0,
            end: 30,
            expected: nil,
        ),
    ]

    @Test("bestMatch", arguments: cases)
    func bestMatch(_ testCase: Case) {
        let match = CalendarEventMatcher.bestMatch(
            testCase.events,
            start: Self.at(testCase.start),
            end: testCase.end.map(Self.at),
        )
        #expect(match?.title == testCase.expected)
    }

    @Test("requireAttendees false keeps solo events")
    func soloEventsWhenAllowed() {
        let match = CalendarEventMatcher.bestMatch(
            [Self.event("Focus", from: 0, to: 60, attendees: 0)],
            start: Self.at(0),
            end: Self.at(30),
            requireAttendees: false,
        )
        #expect(match?.title == "Focus")
    }
}
