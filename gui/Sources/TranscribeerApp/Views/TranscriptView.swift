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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(lines) { line in
                        TranscriptRow(
                            line: line,
                            isActive: isActive(line),
                            onSeek: onSeek,
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

    private var isRTL: Bool { TextDirection.isRightToLeft(line.text) }
    private var direction: LayoutDirection { isRTL ? .rightToLeft : .leftToRight }
    private var textAlignment: TextAlignment { isRTL ? .trailing : .leading }
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
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    /// Stable speaker → color mapping. `Speaker 1`, `Speaker 2`, ... get
    /// distinct accents; `???` (unknown) stays muted.
    private func speakerColor(for speaker: String) -> Color {
        guard speaker != "???" else { return .secondary }
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .green]
        let hash = abs(speaker.hashValue)
        return palette[hash % palette.count]
    }
}

// MARK: - Text direction

/// Right-to-left script detection for transcript rendering.
///
/// WhisperKit emits transcripts with native scripts (Hebrew, Arabic, etc.)
/// but no directionality metadata. SwiftUI's `Text` renders individual
/// glyphs correctly, but paragraph alignment and line wrapping only flip
/// when the surrounding `layoutDirection` is RTL — otherwise a Hebrew
/// sentence reads as if glued together backwards.
enum TextDirection {
    /// Detect whether a string is predominantly right-to-left by looking at
    /// Unicode strong-directional characters. Covers Hebrew, Arabic, Syriac,
    /// N'Ko, Thaana and friends — all of `U+0590…U+08FF` plus Arabic
    /// presentation forms.
    ///
    /// Uses a majority vote so mixed content (e.g. English product names
    /// inside a Hebrew sentence) still flips when the RTL script dominates.
    static func isRightToLeft(_ text: String) -> Bool {
        var rtl = 0
        var ltr = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            // Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan, Mandaic, etc.
            if (0x0590...0x08FF).contains(value)
                || (0xFB1D...0xFDFF).contains(value)
                || (0xFE70...0xFEFF).contains(value) {
                rtl += 1
            } else if (0x0041...0x007A).contains(value)
                || (0x00C0...0x024F).contains(value)
                || (0x0370...0x052F).contains(value) {
                ltr += 1
            }
        }
        return rtl > ltr
    }
}
