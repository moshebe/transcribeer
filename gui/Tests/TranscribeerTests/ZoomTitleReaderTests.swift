import Testing
@testable import TranscribeerApp

struct ZoomTitleReaderTests {
    // MARK: - acceptInfoButtonTitle (new title-bar button source)

    @Test("acceptInfoButtonTitle returns raw string for valid topics", arguments: [
        ("Konstantin Ostrovsky's Zoom Meeting", "Konstantin Ostrovsky's Zoom Meeting"),
        ("Alice's Personal Meeting Room", "Alice's Personal Meeting Room"),
        ("Weekly Staff Sync", "Weekly Staff Sync"),
        ("1:1 with Alice", "1:1 with Alice"),
        ("  Padded Topic  ", "Padded Topic"),
    ])
    func acceptsMeetingTopics(pair: (String, String)) {
        #expect(ZoomTitleReader.acceptInfoButtonTitle(pair.0) == pair.1)
    }

    @Test("acceptInfoButtonTitle rejects control-action labels", arguments: [
        "Mute", "unmute",
        "Start Video", "Stop Video",
        "Participants", "Chat", "Share Screen", "Stop Share",
        "Reactions", "More", "View", "Settings",
        "Leave", "End", "Leave Meeting", "End Meeting",
        "Record", "Breakout Rooms", "Apps", "Whiteboard",
    ])
    func rejectsControlButtons(title: String) {
        #expect(ZoomTitleReader.acceptInfoButtonTitle(title) == nil)
    }

    @Test("acceptInfoButtonTitle rejects home / untitled / empty", arguments: [
        "", "   ",
        "Zoom", "Zoom Workplace",
        "Zoom Meeting", "zoom meeting",
    ])
    func rejectsHomeOrGeneric(title: String) {
        #expect(ZoomTitleReader.acceptInfoButtonTitle(title) == nil)
    }

    // MARK: - extractInfoButtonTopic (title + description + identifier)

    @Test("description wins when title empty on known info button")
    func descriptionWinsForKnownIdentifier() {
        let topic = ZoomTitleReader.extractInfoButtonTopic(
            title: "",
            description: "Konstantin Ostrovsky's Zoom Meeting",
            identifier: "MeetingTopBarInfoButton",
        )
        #expect(topic == "Konstantin Ostrovsky's Zoom Meeting")
    }

    @Test("legacy identifier also accepts description fallback")
    func descriptionWinsForLegacyIdentifier() {
        let topic = ZoomTitleReader.extractInfoButtonTopic(
            title: nil,
            description: "Weekly Staff Sync",
            identifier: "ZMMeetingInfoButton",
        )
        #expect(topic == "Weekly Staff Sync")
    }

    @Test("description ignored for unknown identifiers to avoid false positives")
    func descriptionIgnoredForUnknownIdentifier() {
        let topic = ZoomTitleReader.extractInfoButtonTopic(
            title: "",
            description: "Unmute my audio",
            identifier: "AudioButton",
        )
        #expect(topic == nil)
    }

    @Test("title preferred when both title and description are valid")
    func titlePreferredOverDescription() {
        let topic = ZoomTitleReader.extractInfoButtonTopic(
            title: "Board Review",
            description: "Alice's Zoom Meeting",
            identifier: "MeetingTopBarInfoButton",
        )
        #expect(topic == "Board Review")
    }

    @Test("generic 'Zoom Meeting' description is still rejected on info button")
    func genericDescriptionRejected() {
        let topic = ZoomTitleReader.extractInfoButtonTopic(
            title: "",
            description: "Zoom Meeting",
            identifier: "MeetingTopBarInfoButton",
        )
        #expect(topic == nil)
    }

    @Test("missing identifier falls back to title-only behaviour")
    func missingIdentifierUsesTitleOnly() {
        #expect(ZoomTitleReader.extractInfoButtonTopic(
            title: "Team Standup",
            description: "whatever",
            identifier: nil,
        ) == "Team Standup")
        #expect(ZoomTitleReader.extractInfoButtonTopic(
            title: "",
            description: "Alice's Zoom Meeting",
            identifier: nil,
        ) == nil)
    }

    // MARK: - cleanTitle (legacy window-title fallback)

    @Test("cleanTitle returns nil for home / untitled / empty", arguments: [
        "",
        "   ",
        "Zoom",
        "zoom",
        "Zoom Workplace",
        "Zoom Meeting",
        "zoom meeting",
        "Zoom - Zoom",
    ])
    func emptyOrHome(input: String) {
        #expect(ZoomTitleReader.cleanTitle(input) == nil)
    }

    @Test("cleanTitle strips Zoom suffix and returns topic", arguments: [
        ("Team Standup - Zoom", "Team Standup"),
        ("Quarterly Review | Zoom", "Quarterly Review"),
        ("1:1 with Alice — Zoom", "1:1 with Alice"),
        ("Board – Zoom", "Board"),
        ("Team Standup", "Team Standup"),
    ])
    func topic(pair: (String, String)) {
        #expect(ZoomTitleReader.cleanTitle(pair.0) == pair.1)
    }
}
