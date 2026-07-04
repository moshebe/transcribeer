import Foundation

/// A segment with speaker assignment.
public struct LabeledSegment: Sendable {
    public let start: Double
    public let end: Double
    public let speaker: String
    public let text: String
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

    /// Format labeled segments: rename speakers, merge consecutive
    /// same-speaker lines, produce `[MM:SS -> MM:SS] Speaker N: text`.
    public static func format(_ segments: [LabeledSegment]) -> String {
        guard !segments.isEmpty else { return "" }

        var speakerMap: [String: String] = [:]
        var counter = 1
        for seg in segments where seg.speaker != "UNKNOWN" && speakerMap[seg.speaker] == nil {
            speakerMap[seg.speaker] = "Speaker \(counter)"
            counter += 1
        }
        speakerMap["UNKNOWN"] = "???"

        let renamed = segments.map { seg in
            LabeledSegment(
                start: seg.start,
                end: seg.end,
                speaker: speakerMap[seg.speaker] ?? seg.speaker,
                text: seg.text
            )
        }
        return render(mergeConsecutive(renamed))
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
            "[\(formatTimestamp(seg.start)) -> \(formatTimestamp(seg.end))] \(seg.speaker): \(seg.text)"
        }.joined(separator: "\n")
    }

    /// Formats seconds as MM:SS.
    public static func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
