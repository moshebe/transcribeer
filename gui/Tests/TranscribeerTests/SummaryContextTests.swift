import Foundation
import Testing
@testable import TranscribeerApp

struct SummaryContextTests {
    private let transcript = "[00:01] Speaker 1: Hi Lauren, let's start."
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("With no meeting context the transcript is sent unchanged", arguments: [
        SummaryContext.Meeting(),
        SummaryContext.Meeting(title: "  ", notes: "\n\n"),
    ])
    func noContextKeepsTranscript(meeting: SummaryContext.Meeting) {
        #expect(SummaryContext.userMessage(transcript: transcript, meeting: meeting) == transcript)
    }

    @Test("Participants are listed with their roles so names are spelled right")
    func listsParticipants() {
        let meeting = SummaryContext.Meeting(participants: [
            SessionParticipant(name: "Loren Posendek", observedAt: now, isMe: true),
            SessionParticipant(name: "Aner Izraeli", observedAt: now, isHost: true),
            SessionParticipant(name: "Dana Levi", observedAt: now),
        ])

        let message = SummaryContext.userMessage(transcript: transcript, meeting: meeting)

        #expect(message.contains("- Loren Posendek (me)"))
        #expect(message.contains("- Aner Izraeli (host)"))
        #expect(message.contains("- Dana Levi\n"))
        #expect(message.contains("Spell these names exactly"))
    }

    @Test("Notes and title come before the transcript, which stays last")
    func ordersSections() throws {
        let meeting = SummaryContext.Meeting(
            title: "Q4 planning",
            notes: "- budget owner?\n- ship date",
        )

        let message = SummaryContext.userMessage(transcript: transcript, meeting: meeting)

        let title = try #require(message.range(of: "## Meeting title\nQ4 planning"))
        let notes = try #require(message.range(of: "- budget owner?\n- ship date"))
        let body = try #require(message.range(of: "## Transcript\n\(transcript)"))
        #expect(title.upperBound < notes.lowerBound)
        #expect(notes.upperBound < body.lowerBound)
        #expect(message.hasSuffix(transcript))
    }

    @Test("Meeting context is read from the session's metadata")
    func readsSessionMeta() throws {
        let session = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: session) }
        SessionManager.setName(session, "Weekly sync")
        SessionManager.setNotes(session, "follow up with legal")
        SessionManager.appendParticipants(session, observed: [
            SessionParticipant(name: "Noy Madar", observedAt: now, isCoHost: true),
        ])

        let meeting = SummaryContext.meeting(in: session)

        #expect(meeting.title == "Weekly sync")
        #expect(meeting.notes == "follow up with legal")
        #expect(meeting.participants.map(\.name) == ["Noy Madar"])
        #expect(meeting.participants.first?.isCoHost == true)
    }
}
