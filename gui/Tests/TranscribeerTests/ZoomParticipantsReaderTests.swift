import Testing
@testable import TranscribeerApp

@Suite("ZoomParticipantsReader")
struct ZoomParticipantsReaderTests {
    // MARK: - Label parsing

    @Test(arguments: [
        ("Konstantin Ostrovsky (Host, me)", parsed("Konstantin Ostrovsky", me: true, host: true)),
        ("Alice Example (Co-host)", parsed("Alice Example", coHost: true)),
        ("Bob External (Guest)", parsed("Bob External", guest: true)),
        ("Jane Doe", parsed("Jane Doe")),
        ("Alice (me)", parsed("Alice", me: true)),
        ("Alice (Host, me) (Speaking)", parsed("Alice", me: true, host: true, speaking: true)),
        ("  Padded Name (me)  ", parsed("Padded Name", me: true)),
        // Unrecognized parenthetical → kept as part of the name so user
        // display names like "Alice (she/her)" survive.
        ("Name With (unrelated tag)", parsed("Name With (unrelated tag)")),
    ])
    func parsesLabels(_ raw: String, _ expected: ZoomParticipantsReader.ParsedLabel) {
        #expect(ZoomParticipantsReader.parseLabel(raw) == expected)
    }

    @Test
    func preservesParensInsideName() {
        // Zoom lets users put parens in their display name; we only strip the
        // trailing tag groups, so an inline "(PhD)" should survive.
        let result = ZoomParticipantsReader.parseLabel("Dr. Smith (PhD) (Host, me)")
        #expect(result.name == "Dr. Smith (PhD)")
        #expect(result.isHost)
        #expect(result.isMe)
    }

    // MARK: - Mic state parsing

    @Test(arguments: [
        ("Computer audio muted", ZoomParticipantsReader.MicState.muted),
        ("Computer audio unmuted", .unmuted),
        ("Telephone audio", .phone),
        ("No audio", .noAudio),
    ])
    func parsesMicState(_ description: String, _ expected: ZoomParticipantsReader.MicState) {
        #expect(ZoomParticipantsReader.micStateFromDescription(description) == expected)
    }

    @Test(arguments: ["Video on", "Profile button", "", "Unmute"])
    func nonMicDescriptionsReturnNil(_ description: String) {
        #expect(ZoomParticipantsReader.micStateFromDescription(description) == nil)
    }

    // MARK: - Video state parsing

    @Test(arguments: [
        ("Video on", ZoomParticipantsReader.VideoState.on),
        ("Video off", .off),
    ])
    func parsesVideoState(_ description: String, _ expected: ZoomParticipantsReader.VideoState) {
        #expect(ZoomParticipantsReader.videoStateFromDescription(description) == expected)
    }

    @Test(arguments: ["Computer audio muted", "", "Unmute"])
    func nonVideoDescriptionsReturnNil(_ description: String) {
        #expect(ZoomParticipantsReader.videoStateFromDescription(description) == nil)
    }

    // MARK: - LookupState

    @Test
    func lookupStateShortDescriptions() {
        #expect(ZoomParticipantsReader.LookupState.zoomNotRunning.shortDescription == "zoom-not-running")
        #expect(ZoomParticipantsReader.LookupState.noMeetingWindow.shortDescription == "no-meeting-window")
        #expect(ZoomParticipantsReader.LookupState.panelClosed.shortDescription == "panel-closed")
        #expect(ZoomParticipantsReader.LookupState.found(count: 3).shortDescription == "found(3)")
        #expect(ZoomParticipantsReader.LookupState.axError("boom").shortDescription == "ax-error(boom)")
    }
}

/// Convenience builder so the table-driven parse cases stay one-per-line.
private func parsed(
    _ name: String,
    me: Bool = false,
    host: Bool = false,
    coHost: Bool = false,
    guest: Bool = false,
    speaking: Bool = false,
) -> ZoomParticipantsReader.ParsedLabel {
    ZoomParticipantsReader.ParsedLabel(
        name: name,
        isMe: me,
        isHost: host,
        isCoHost: coHost,
        isGuest: guest,
        isSpeaking: speaking,
    )
}
