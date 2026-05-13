import SwiftUI

/// Renders a parsed transcript as a stack of speaker rows with clickable
/// timestamps. Tapping a timestamp seeks the session's audio player.
///
/// Intended to replace the raw `Text(detail.transcript)` dump. The source of
/// truth is still the plain-text `transcript.txt` on disk — this view parses
/// on the fly so export and copy-paste stay compatible with older sessions.
struct TranscriptView: View {
    /// Either the cleaned disk transcript or the live preview.
    let lines: [TranscriptLine]

    /// Called when the user clicks a `[MM:SS]` badge. Receives the segment
    /// start time in seconds.
    let onSeek: (Double) -> Void

    /// Optional: when non-nil, the row containing this time gets the "now
    /// playing" highlight. Pass the audio player's current time.
    let playheadTime: Double?

    /// When true, shows a subtle placeholder row at the bottom to signal more
    /// text is arriving. Used during live transcription.
    let isStreaming: Bool

    /// The label used for the "other" participant (system audio). Rendered
    /// with a fixed distinct color so it doesn't collide with the hash-based
    /// palette used for diarized speakers.
    let otherLabel: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(lines) { line in
                        TranscriptRow(
                            line: line,
                            isActive: isActive(line),
                            onSeek: onSeek,
                            otherLabel: otherLabel
                        )
                        .id(line.id)
                    }

                    if isStreaming {
                        streamingIndicator
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { _, _ in
                guard isStreaming, let last = lines.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func isActive(_ line: TranscriptLine) -> Bool {
        guard let playheadTime else { return false }
        return playheadTime >= line.start && playheadTime < line.end
    }

    private var streamingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Listening…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }
}

// MARK: - Row

private struct TranscriptRow: View {
    let line: TranscriptLine
    let isActive: Bool
    let onSeek: (Double) -> Void
    let otherLabel: String?

    private var isRTL: Bool { TextDirection.containsRightToLeft(line.text) }
    private var direction: LayoutDirection { isRTL ? .rightToLeft : .leftToRight }
    // Always `.leading` — the `\.layoutDirection` env on the Text already
    // flips leading→right for RTL. Using `.trailing` under an RTL env would
    // align wrapped lines to the left edge (wrong for Hebrew/Arabic).
    private var textAlignment: TextAlignment { .leading }
    private var frameAlignment: Alignment { isRTL ? .trailing : .leading }
    private var activeEdge: Alignment { isRTL ? .trailing : .leading }

    var body: some View {
        VStack(alignment: isRTL ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    onSeek(line.start)
                } label: {
                    Text(formatTimestamp(line.start))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.accentColor.opacity(0.1)),
                        )
                }
                .buttonStyle(.plain)
                .help("Jump to \(formatTimestamp(line.start))")

                Text(line.speaker)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(speakerColor(for: line.speaker))
            }
            // Timestamp + speaker chip always read left-to-right — MM:SS and
            // "Speaker 1" aren't localized strings. The body flips separately.
            .environment(\.layoutDirection, .leftToRight)
            .frame(maxWidth: .infinity, alignment: frameAlignment)

            Text(line.text)
                .font(.system(size: 13))
                .lineSpacing(3)
                .multilineTextAlignment(textAlignment)
                .environment(\.layoutDirection, direction)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: frameAlignment)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.08) : Color.clear),
        )
        .overlay(alignment: activeEdge) {
            if isActive {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Stable speaker → color mapping. `Speaker 1`, `Speaker 2`, ... get
    /// distinct accents; `???` (unknown) stays muted; the configured
    /// `otherLabel` (e.g. "Them") gets a fixed distinct color.
    ///
    /// Uses a deterministic djb2 hash over unicode scalars rather than
    /// `String.hashValue` — Swift seeds its hasher per process, so
    /// `hashValue` produces different numbers each launch and would flip
    /// speaker colors between app runs.
    private func speakerColor(for speaker: String) -> Color {
        guard speaker != "???" else { return .secondary }
        if let otherLabel, speaker == otherLabel {
            return .red
        }
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .green]
        return palette[Self.stableHash(speaker) % palette.count]
    }

    /// djb2: deterministic across launches. UInt so arithmetic wraps cleanly
    /// without overflow.
    private static func stableHash(_ string: String) -> Int {
        var hash: UInt = 5381
        for scalar in string.unicodeScalars {
            hash = hash &* 33 &+ UInt(scalar.value)
        }
        return Int(hash & UInt(Int.max))
    }
}

// MARK: - Text direction

/// Right-to-left script detection for transcript and summary rendering.
///
/// WhisperKit / LLMs emit text with native scripts (Hebrew, Arabic, etc.)
/// but no directionality metadata. SwiftUI's `Text` renders individual
/// glyphs correctly, but paragraph alignment, list markers and line
/// wrapping only flip when the surrounding `layoutDirection` is RTL —
/// otherwise a Hebrew sentence reads as if glued together backwards.
///
/// Policy: any single strong RTL character in the input flips the whole
/// block to RTL. Mixed content (Hebrew prose with embedded English
/// product names, code identifiers, etc.) is the common case and should
/// always render RTL; pure-Latin text stays LTR.
enum TextDirection {
    /// Returns `true` if `text` contains any Unicode strong right-to-left
    /// character. Covers Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan,
    /// Mandaic — all of `U+0590…U+08FF` — plus Arabic presentation forms.
    static func containsRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x0590...0x08FF).contains(value)
                || (0xFB1D...0xFDFF).contains(value)
                || (0xFE70...0xFEFF).contains(value) {
                return true
            }
        }
        return false
    }
}
