import SwiftUI

/// Compact single-line list of meeting participants captured while the
/// session was recording. Truncates with ellipsis; full roster with role
/// tags lives in the tooltip.
struct SessionParticipantsRow: View {
    let participants: [SessionParticipant]

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.2")
                .font(.system(size: 11))
            Text(Self.summary(participants))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
        .help(Self.tooltip(participants))
    }

    /// Inline comma-separated summary. "(me)" is appended to the user's own
    /// row so they can quickly orient themselves in larger lists.
    static func summary(_ participants: [SessionParticipant]) -> String {
        let names = participants.map { participant in
            participant.isMe ? "\(participant.name) (me)" : participant.name
        }
        return "\(participants.count): " + names.joined(separator: ", ")
    }

    /// Multi-line tooltip with every role flag spelled out. One bullet per
    /// participant, preserving the list's stored order (first-seen first).
    static func tooltip(_ participants: [SessionParticipant]) -> String {
        participants.map { participant in
            var tags: [String] = []
            if participant.isMe { tags.append("me") }
            if participant.isHost { tags.append("host") }
            if participant.isCoHost { tags.append("co-host") }
            if participant.isGuest { tags.append("guest") }
            let suffix = tags.isEmpty ? "" : " (\(tags.joined(separator: ", ")))"
            return "• \(participant.name)\(suffix)"
        }
        .joined(separator: "\n")
    }
}
