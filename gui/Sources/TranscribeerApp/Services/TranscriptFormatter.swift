import Foundation

/// A segment with speaker assignment.
struct LabeledSegment {
    let start: Double
    let end: Double
    let speaker: String
    let text: String
}

/// A parsed transcript line: one speaker, a [start, end] window, cleaned text.
/// Used by the transcript viewer to render clickable timestamps.
struct TranscriptLine: Identifiable, Hashable {
    let id: Int
    let start: Double
    let end: Double
    let speaker: String
    let text: String
}

/// Ports assign_speakers() and format_output() from Python transcribe.py.
enum TranscriptFormatter {
    /// Assign a speaker label to each whisper segment based on overlap
    /// with diarization segments. Falls back to midpoint containment.
    static func assignSpeakers(
        whisperSegments: [TranscriptSegment],
        diarSegments: [DiarSegment]
    ) -> [LabeledSegment] {
        whisperSegments.map { ws in
            let wsMid = (ws.start + ws.end) / 2
            var bestSpeaker = "UNKNOWN"
            var bestOverlap = 0.0

            for ds in diarSegments {
                let overlap = max(0, min(ws.end, ds.end) - max(ws.start, ds.start))
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = ds.speaker
                }
                if bestOverlap == 0 && ds.start <= wsMid && wsMid <= ds.end {
                    bestSpeaker = ds.speaker
                }
            }

            return LabeledSegment(
                start: ws.start,
                end: ws.end,
                speaker: bestSpeaker,
                text: ws.text
            )
        }
    }

    /// Format labeled segments: rename speakers, merge consecutive
    /// same-speaker lines, produce `[MM:SS -> MM:SS] Speaker N: text`.
    static func format(_ segments: [LabeledSegment]) -> String {
        guard !segments.isEmpty else { return "" }

        // Build stable speaker name mapping (first-seen order).
        var speakerMap: [String: String] = [:]
        var counter = 1
        for seg in segments
            where seg.speaker != "UNKNOWN" && speakerMap[seg.speaker] == nil {
            speakerMap[seg.speaker] = "Speaker \(counter)"
            counter += 1
        }
        speakerMap["UNKNOWN"] = "???"

        let renamed = segments.map { seg in
            MergedLine(
                start: seg.start,
                end: seg.end,
                speaker: speakerMap[seg.speaker] ?? seg.speaker,
                text: seg.text
            )
        }
        return render(mergeConsecutive(renamed))
    }

    /// Strip Whisper special tokens (e.g. `<|startoftranscript|>`, `<|he|>`,
    /// `<|0.00|>`, `<|endoftext|>`) and collapse whitespace.
    ///
    /// New transcripts pass `skipSpecialTokens: true` so WhisperKit never emits
    /// these tokens in the first place. This stays as a defense-in-depth /
    /// migration step for older `transcript.txt` files written before that fix.
    static func sanitize(_ text: String) -> String {
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
    /// `format(_:)`. Lines that don't match the header pattern are folded into
    /// the previous line's text (so hard-wrapped paragraphs stay intact).
    /// Supports `HH:MM:SS` timestamps too, for long recordings.
    static func parse(_ transcript: String) -> [TranscriptLine] {
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

    /// Internal accumulator for merging consecutive same-speaker segments.
    private struct MergedLine {
        var start: Double
        var end: Double
        var speaker: String
        var text: String
    }

    /// Format labeled segments for dual-source output: use speaker labels
    /// directly (no renumbering), merge consecutive same-speaker lines.
    static func formatDual(_ segments: [LabeledSegment]) -> String {
        guard !segments.isEmpty else { return "" }
        let lines = segments.map { seg in
            MergedLine(start: seg.start, end: seg.end, speaker: seg.speaker, text: seg.text)
        }
        return render(mergeConsecutive(lines))
    }

    /// Merge consecutive lines with the same speaker.
    private static func mergeConsecutive(_ lines: [MergedLine]) -> [MergedLine] {
        var merged: [MergedLine] = []
        for line in lines {
            if let last = merged.last, last.speaker == line.speaker {
                let prev = merged.removeLast()
                merged.append(MergedLine(
                    start: prev.start,
                    end: line.end,
                    speaker: prev.speaker,
                    text: prev.text + " " + line.text
                ))
            } else {
                merged.append(line)
            }
        }
        return merged
    }

    private static func render(_ lines: [MergedLine]) -> String {
        lines.map { line in
            let ts = "[\(formatTimestamp(line.start)) -> \(formatTimestamp(line.end))]"
            return "\(ts) \(line.speaker): \(sanitize(line.text))"
        }.joined(separator: "\n")
    }

    /// Formats seconds as MM:SS.
    static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
