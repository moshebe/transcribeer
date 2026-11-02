import Foundation

/// Builds the summarizer's user message: what we know about the meeting,
/// followed by the transcript.
///
/// Speech recognition misspells names ("Lauren" for "Loren") and can't tell
/// which moments mattered to the user. The participants list gives the model
/// the correct spellings, and the user's own notes act as the outline of what
/// was important. With no context the transcript is sent unchanged.
enum SummaryContext {
    struct Meeting: Equatable {
        var title: String = ""
        var participants: [SessionParticipant] = []
        var notes: String = ""
    }

    static func meeting(in session: URL) -> Meeting {
        let meta = SessionManager.readMeta(session)
        return Meeting(
            title: meta["name"] as? String ?? "",
            participants: SessionManager.participants(session),
            notes: meta["notes"] as? String ?? "",
        )
    }

    static func userMessage(transcript: String, meeting: Meeting) -> String {
        var sections: [String] = []

        let title = meeting.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            sections.append("## Meeting title\n\(title)")
        }

        if !meeting.participants.isEmpty {
            let lines = meeting.participants.map { "- \(label(for: $0))" }
            sections.append(
                """
                ## Participants
                Spell these names exactly as written here, even where the \
                transcript misspells them. "(me)" is the person you are \
                writing the summary for.
                \(lines.joined(separator: "\n"))
                """
            )
        }

        let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            sections.append(
                """
                ## My notes
                Notes I took during the meeting. Treat them as the outline of \
                what mattered: cover every point in them, expand each with \
                details from the transcript, and never contradict the transcript.
                \(notes)
                """
            )
        }

        guard !sections.isEmpty else { return transcript }
        sections.append("## Transcript\n\(transcript)")
        return sections.joined(separator: "\n\n")
    }

    private static func label(for participant: SessionParticipant) -> String {
        var roles: [String] = []
        if participant.isMe { roles.append("me") }
        if participant.isHost { roles.append("host") }
        if participant.isCoHost { roles.append("co-host") }
        if participant.isGuest { roles.append("guest") }
        return roles.isEmpty ? participant.name : "\(participant.name) (\(roles.joined(separator: ", ")))"
    }
}
