import EventKit
import Foundation
import Testing
@testable import TranscribeerApp

struct CalendarEnricherTests {
    private static func makeSessionDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribeer-calendar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var enabledConfig: AppConfig {
        var config = AppConfig()
        config.calendarEnricherEnabled = true
        return config
    }

    private static let oneOnOne = CalendarEventMatcherTests.event("Itay / Or - 1:1", from: 30, to: 55)

    // MARK: - meta.json

    @Test("calendar_event round-trips through meta.json")
    func metaRoundTrip() throws {
        let dir = try Self.makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        SessionManager.setCalendarEvent(dir, Self.oneOnOne, stage: .stop)

        #expect(SessionManager.readCalendarEvent(dir) == Self.oneOnOne)
        let raw = SessionManager.readMeta(dir)[SessionManager.calendarEventKey] as? [String: Any]
        #expect(raw?["matched_at"] as? String == "stop")
    }

    // MARK: - Name precedence

    struct NameCase: CustomTestStringConvertible, Sendable {
        let current: String
        let currentSource: SessionNameSource?
        let incoming: SessionNameSource
        let replaces: Bool
        var testDescription: String {
            "\(currentSource?.rawValue ?? "none") '\(current)' <- \(incoming.rawValue): \(replaces)"
        }
    }

    @Test("shouldReplaceName", arguments: [
        NameCase(current: "", currentSource: nil, incoming: .zoom, replaces: true),
        NameCase(current: "", currentSource: nil, incoming: .calendar, replaces: true),
        NameCase(current: "Mine", currentSource: .user, incoming: .calendar, replaces: false),
        NameCase(current: "Legacy", currentSource: nil, incoming: .calendar, replaces: false),
        NameCase(current: "Zoom topic", currentSource: .zoom, incoming: .calendar, replaces: true),
        NameCase(current: "Event", currentSource: .calendar, incoming: .zoom, replaces: false),
        NameCase(current: "Event", currentSource: .calendar, incoming: .calendar, replaces: true),
    ])
    func nameReplacement(_ testCase: NameCase) {
        let result = SessionManager.shouldReplaceName(
            current: testCase.current,
            currentSource: testCase.currentSource,
            with: testCase.incoming,
        )
        #expect(result == testCase.replaces)
    }

    @Test("setName records the user as the name source by default")
    func userRenameSetsSource() throws {
        let dir = try Self.makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        SessionManager.setName(dir, "Mine")
        #expect(SessionManager.readMeta(dir)["name_source"] as? String == "user")
        #expect(!SessionManager.setAutomaticName(dir, "Event", source: .calendar))
        #expect(SessionManager.displayName(dir) == "Mine")
    }

    // MARK: - enrich

    @Test("enrich saves the event and names an unnamed session")
    func enrichNamesSession() async throws {
        let dir = try Self.makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let line = await CalendarEnricher.enrich(
            session: dir,
            start: CalendarEventMatcherTests.at(38),
            end: CalendarEventMatcherTests.at(61),
            stage: .stop,
            config: Self.enabledConfig,
            events: { _ in [Self.oneOnOne] },
        )

        #expect(line?.contains("matched") == true)
        #expect(SessionManager.readCalendarEvent(dir)?.title == "Itay / Or - 1:1")
        #expect(SessionManager.displayName(dir) == "Itay / Or - 1:1")
        #expect(SessionManager.readMeta(dir)["name_source"] as? String == "calendar")
    }

    @Test("enrich keeps a name the user typed")
    func enrichKeepsUserName() async throws {
        let dir = try Self.makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        SessionManager.setName(dir, "Mine")

        await CalendarEnricher.enrich(
            session: dir,
            start: CalendarEventMatcherTests.at(38),
            end: CalendarEventMatcherTests.at(61),
            stage: .stop,
            config: Self.enabledConfig,
            events: { _ in [Self.oneOnOne] },
        )

        #expect(SessionManager.displayName(dir) == "Mine")
        #expect(SessionManager.readCalendarEvent(dir) != nil)
    }

    @Test("enrich does nothing when the enricher is off")
    func enrichDisabled() async throws {
        let dir = try Self.makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let line = await CalendarEnricher.enrich(
            session: dir,
            start: CalendarEventMatcherTests.at(38),
            end: nil,
            stage: .start,
            config: AppConfig(),
            events: { _ in [Self.oneOnOne] },
        )

        #expect(line == nil)
        #expect(SessionManager.readCalendarEvent(dir) == nil)
    }

    @Test("enrich reports no match and writes nothing")
    func enrichNoMatch() async throws {
        let dir = try Self.makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let line = await CalendarEnricher.enrich(
            session: dir,
            start: CalendarEventMatcherTests.at(120),
            end: CalendarEventMatcherTests.at(150),
            stage: .stop,
            config: Self.enabledConfig,
            events: { _ in [Self.oneOnOne] },
        )

        #expect(line?.contains("no match") == true)
        #expect(SessionManager.readCalendarEvent(dir) == nil)
    }

    @Test("stop with no match removes the start-time match and its name")
    func stopClearsStartGuess() async throws {
        let dir = try Self.makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let forum = CalendarEventMatcherTests.event("AI forum", from: 0, to: 60, attendees: 54)

        await CalendarEnricher.enrich(
            session: dir,
            start: CalendarEventMatcherTests.at(17),
            end: nil,
            stage: .start,
            config: Self.enabledConfig,
            events: { _ in [forum] },
        )
        #expect(SessionManager.displayName(dir) == "AI forum")

        let line = await CalendarEnricher.enrich(
            session: dir,
            start: CalendarEventMatcherTests.at(17),
            end: CalendarEventMatcherTests.at(33),
            stage: .stop,
            config: Self.enabledConfig,
            events: { _ in [] },
        )

        #expect(line?.contains("cleared earlier match") == true)
        #expect(SessionManager.readCalendarEvent(dir) == nil)
        #expect(SessionManager.readMeta(dir)["name"] == nil)
        #expect(SessionManager.readMeta(dir)["name_source"] == nil)
    }

    @Test("clearing a calendar match keeps a name the user typed")
    func clearKeepsUserName() throws {
        let dir = try Self.makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        SessionManager.setCalendarEvent(dir, Self.oneOnOne, stage: .start)
        SessionManager.setName(dir, "Mine")

        #expect(SessionManager.clearCalendarMatch(dir))
        #expect(SessionManager.displayName(dir) == "Mine")
        #expect(SessionManager.readCalendarEvent(dir) == nil)
    }

    // MARK: - EventKit mapping helpers

    @Test("email(fromParticipantURL:)", arguments: [
        ("mailto:Itay.Pahima@example.com", "itay.pahima@example.com"),
        ("MAILTO:a%2Bb@example.com", "a+b@example.com"),
        ("urn:uuid:1234", nil),
        ("mailto:", nil),
    ] as [(String, String?)])
    func participantEmail(raw: String, expected: String?) throws {
        let url = try #require(URL(string: raw))
        #expect(CalendarEventReader.email(fromParticipantURL: url) == expected)
    }

    @Test("participant status mapping", arguments: [
        (EKParticipantStatus.accepted, CalendarEvent.ResponseStatus.accepted),
        (.declined, .declined),
        (.tentative, .tentative),
        (.pending, .pending),
        (.delegated, .accepted),
        (.unknown, .unknown),
    ])
    func statusMapping(status: EKParticipantStatus, expected: CalendarEvent.ResponseStatus) {
        #expect(CalendarEventReader.status(status) == expected)
    }
}
