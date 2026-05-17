import SwiftUI
import TranscribeerCore

/// Single row in the history sidebar. Renders the session name, a compact
/// date/time + language line, and the three artifact glyphs (audio,
/// transcript, summary) that tell users at a glance which pipeline stages
/// have run for the session. Extracted from `HistoryView` so the host file
/// stays under SwiftLint's file-length cap.
struct SessionRow: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(session.name)
                    .font(.system(size: 13, weight: session.isUntitled ? .regular : .semibold))
                    .foregroundStyle(session.isUntitled ? .secondary : .primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                artifactIcons
            }

            // Always show the date/time line. Named sessions (e.g. Zoom
            // meetings auto-named "Pytorq - Daily") would otherwise collapse
            // to just the title, making multiple instances of a recurring
            // meeting visually indistinguishable in the sidebar.
            HStack(spacing: 4) {
                Text(SessionDateFormatter.sidebarLine(for: session))
                if let badge = languageBadge {
                    Text(badge)
                        .font(.system(size: 9, weight: .medium))
                        .tracking(0.5)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if !session.snippet.isEmpty {
                Text(session.snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    /// Small glyph trio on the right of each row showing which artifacts
    /// exist for the session: audio, transcript, summary. A dimmed glyph
    /// means the artifact is missing — so users can see at a glance whether
    /// a session still needs transcribing or summarizing.
    @ViewBuilder
    private var artifactIcons: some View {
        HStack(spacing: 4) {
            artifactIcon(
                systemName: "waveform",
                present: session.hasAudio,
                help: session.hasAudio ? "Audio recorded" : "No audio"
            )
            artifactIcon(
                systemName: "text.alignleft",
                present: session.hasTranscript,
                help: session.hasTranscript ? "Transcript available" : "Not transcribed"
            )
            artifactIcon(
                systemName: "sparkles",
                present: session.hasSummary,
                help: session.hasSummary ? "Summary available" : "Not summarized"
            )
        }
    }

    private func artifactIcon(systemName: String, present: Bool, help: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(present ? Color.accentColor : Color.secondary.opacity(0.35))
            .help(help)
            .accessibilityLabel(help)
    }

    private var languageBadge: String? {
        session.language.flatMap { TranscriptionLanguage.from($0).badgeText }
    }
}
