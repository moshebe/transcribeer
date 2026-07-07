import Foundation

/// A segment with speaker assignment.
public struct LabeledSegment: Sendable {
    public let start: Double
    public let end: Double
    public let speaker: String
    public let text: String

    public init(start: Double, end: Double, speaker: String, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

/// A parsed transcript line: one speaker, a [start, end] window, cleaned text.
/// Used by the transcript viewer to render clickable timestamps.
public struct TranscriptLine: Identifiable, Hashable, Sendable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let speaker: String
    public let text: String

    public init(id: Int, start: Double, end: Double, speaker: String, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}

/// Merges Whisper segments with diarization and formats the transcript.
public enum TranscriptFormatter {
    /// Assign a speaker label to each Whisper segment based on overlap
    /// with diarization segments.
    ///
    /// Matching priority:
    /// 1. Maximum temporal overlap — the diar segment that shares the most
    ///    time with the whisper segment wins.
    /// 2. Nearest segment — when no diar segment overlaps at all, pick the
    ///    one with the smallest temporal distance to the whisper midpoint.
    ///    This handles tail segments that extend past the last diarized
    ///    interval (pyannote often truncates the tail), ensuring they snap
    ///    to the last real speaker rather than defaulting to UNKNOWN or
    ///    being stolen by an earlier long segment via midpoint containment.
    ///
    /// Falls back to "UNKNOWN" only when `diarSegments` is empty.
    public static func assignSpeakers(
        whisperSegments: [TranscriptSegment],
        diarSegments: [DiarSegment]
    ) -> [LabeledSegment] {
        // Sort once for deterministic distance tie-breaking (nearest end/start).
        let sorted = diarSegments.sorted { $0.start < $1.start }

        return whisperSegments.map { ws in
            guard !sorted.isEmpty else {
                return LabeledSegment(start: ws.start, end: ws.end, speaker: "UNKNOWN", text: ws.text)
            }

            let wsMid = (ws.start + ws.end) / 2

            // Primary pass: find best overlap.
            var bestOverlap = 0.0
            var bestSpeaker = ""
            for ds in sorted {
                let overlap = max(0, min(ws.end, ds.end) - max(ws.start, ds.start))
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = ds.speaker
                }
            }

            if bestOverlap > 0 {
                return LabeledSegment(start: ws.start, end: ws.end, speaker: bestSpeaker, text: ws.text)
            }

            // Fallback: nearest diar segment by distance from whisper midpoint.
            // Distance is 0 when midpoint is inside the diar segment (containment),
            // otherwise the gap from the midpoint to the nearest edge.
            let speaker = sorted.min(by: { distanceToMid($0, mid: wsMid) < distanceToMid($1, mid: wsMid) })?.speaker
                ?? "UNKNOWN"
            return LabeledSegment(start: ws.start, end: ws.end, speaker: speaker, text: ws.text)
        }
    }

    /// Temporal distance from `mid` to the diar segment.
    /// Returns 0 when `mid` is inside the segment, otherwise the gap length.
    private static func distanceToMid(_ ds: DiarSegment, mid: Double) -> Double {
        if ds.start <= mid && mid <= ds.end { return 0 }
        return mid < ds.start ? ds.start - mid : mid - ds.end
    }

    /// Format labeled segments for dual-source output: use speaker labels
    /// directly (no renumbering), merge consecutive same-speaker lines.
    public static func formatDual(_ segments: [LabeledSegment]) -> String {
        guard !segments.isEmpty else { return "" }
        return render(mergeConsecutive(segments))
    }

    /// Merge consecutive segments with the same speaker; `end` and `text` are
    /// accumulated, `start` and `speaker` come from the first segment in the run.
    private static func mergeConsecutive(_ segments: [LabeledSegment]) -> [LabeledSegment] {
        var merged: [LabeledSegment] = []
        for seg in segments {
            if let last = merged.last, last.speaker == seg.speaker {
                let prev = merged.removeLast()
                merged.append(LabeledSegment(
                    start: prev.start,
                    end: seg.end,
                    speaker: prev.speaker,
                    text: prev.text + " " + seg.text
                ))
            } else {
                merged.append(seg)
            }
        }
        return merged
    }

    private static func render(_ segments: [LabeledSegment]) -> String {
        segments.map { seg in
            "[\(formatTimestamp(seg.start)) -> \(formatTimestamp(seg.end))] \(seg.speaker): \(sanitize(seg.text))"
        }.joined(separator: "\n")
    }

    /// Formats seconds as MM:SS.
    public static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    /// Strip Whisper special tokens (e.g. `<|startoftranscript|>`, `<|he|>`,
    /// `<|0.00|>`, `<|endoftext|>`) and collapse whitespace.
    ///
    /// New transcripts pass `skipSpecialTokens: true` so WhisperKit never emits
    /// these tokens in the first place. This stays as a defense-in-depth /
    /// migration step for older `transcript.txt` files written before that fix.
    public static func sanitize(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(
            of: #"<\|[^|]*\|>"#,
            with: " ",
            options: .regularExpression,
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression,
        )
        return cleaned.trimmingCharacters(in: .whitespaces)
    }

    /// Parse a formatted transcript string back into structured lines.
    ///
    /// Accepts the `[MM:SS -> MM:SS] Speaker: text` shape produced by
    /// `formatDual(_:)`. Lines that don't match the header pattern are folded
    /// into the previous line's text (so hard-wrapped paragraphs stay intact).
    /// Supports `HH:MM:SS` timestamps too, for long recordings.
    public static func parse(_ transcript: String) -> [TranscriptLine] {
        guard !transcript.isEmpty else { return [] }

        let pattern = #"^\[(\d{1,2}(?::\d{2}){1,2}) -> (\d{1,2}(?::\d{2}){1,2})\]\s+([^:]+?):\s*(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        var lines: [TranscriptLine] = []
        var nextID = 0
        for raw in transcript.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex.firstMatch(in: trimmed, range: range), match.numberOfRanges == 5,
               let startRange = Range(match.range(at: 1), in: trimmed),
               let endRange = Range(match.range(at: 2), in: trimmed),
               let speakerRange = Range(match.range(at: 3), in: trimmed),
               let textRange = Range(match.range(at: 4), in: trimmed) {
                lines.append(TranscriptLine(
                    id: nextID,
                    start: parseTimestamp(String(trimmed[startRange])),
                    end: parseTimestamp(String(trimmed[endRange])),
                    speaker: String(trimmed[speakerRange]).trimmingCharacters(in: .whitespaces),
                    text: sanitize(String(trimmed[textRange])),
                ))
                nextID += 1
            } else if var last = lines.popLast() {
                let cleaned = sanitize(trimmed)
                last = TranscriptLine(
                    id: last.id,
                    start: last.start,
                    end: last.end,
                    speaker: last.speaker,
                    text: last.text.isEmpty ? cleaned : last.text + " " + cleaned,
                )
                lines.append(last)
            }
        }
        return lines
    }

    /// Parse `MM:SS` or `HH:MM:SS` into seconds. Returns 0 on malformed input.
    private static func parseTimestamp(_ string: String) -> Double {
        let parts = string.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 2: return Double(parts[0] * 60 + parts[1])
        case 3: return Double(parts[0] * 3600 + parts[1] * 60 + parts[2])
        default: return 0
        }
    }
}
