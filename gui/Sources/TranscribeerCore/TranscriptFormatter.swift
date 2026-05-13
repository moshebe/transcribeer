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
    /// with diarization segments. Falls back to midpoint containment.
    public static func assignSpeakers(
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
