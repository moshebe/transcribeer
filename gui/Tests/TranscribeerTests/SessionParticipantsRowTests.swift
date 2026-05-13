import Foundation
import Testing
@testable import TranscribeerApp

@Suite("SessionParticipantsRow")
struct SessionParticipantsRowTests {
    @Test
    func summaryPrefixesCountAndMarksMe() {
        let now = Date(timeIntervalSince1970: 1_000)
        let participants = [
            SessionParticipant(name: "Alice", observedAt: now, isHost: true),
            SessionParticipant(name: "Bob", observedAt: now, isMe: true),
            SessionParticipant(name: "Charlie", observedAt: now),
        ]
        #expect(SessionParticipantsRow.summary(participants) == "3: Alice, Bob (me), Charlie")
    }

    @Test
    func summaryEmptyListStillRenders() {
        #expect(SessionParticipantsRow.summary([]) == "0: ")
    }

    @Test
    func tooltipLinesIncludeRoleTags() {
        let now = Date(timeIntervalSince1970: 1_000)
        let participants = [
            SessionParticipant(name: "Alice", observedAt: now, isMe: true, isHost: true),
            SessionParticipant(name: "Bob", observedAt: now, isCoHost: true),
            SessionParticipant(name: "Charlie", observedAt: now, isGuest: true),
            SessionParticipant(name: "Dana", observedAt: now),
        ]
        let expected = """
        • Alice (me, host)
        • Bob (co-host)
        • Charlie (guest)
        • Dana
        """
        #expect(SessionParticipantsRow.tooltip(participants) == expected)
    }
}
