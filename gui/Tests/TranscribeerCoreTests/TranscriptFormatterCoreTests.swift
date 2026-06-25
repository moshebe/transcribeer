import Testing
@testable import TranscribeerCore

struct TranscriptFormatterCoreTests {
    // MARK: - assignSpeakers: overlap (primary path)

    @Test("Best-overlap speaker wins")
    func overlapWins() {
        let whisper = [
            TranscriptSegment(start: 0, end: 10, text: "Hello"),
            TranscriptSegment(start: 10, end: 20, text: "World"),
        ]
        let diar = [
            DiarSegment(start: 0, end: 12, speaker: "A"),
            DiarSegment(start: 8, end: 20, speaker: "B"),
        ]
        let result = TranscriptFormatter.assignSpeakers(
            whisperSegments: whisper, diarSegments: diar
        )
        // 0-10 overlaps A by 10s, B by 2s → A
        #expect(result[0].speaker == "A")
        // 10-20 overlaps A by 2s, B by 10s → B
        #expect(result[1].speaker == "B")
    }

    // MARK: - assignSpeakers: nearest-segment fallback

    @Test("Tail segment beyond last diar interval snaps to last speaker")
    func tailSegmentSnapsToLastSpeaker() {
        // Pyannote stops at t=10; whisper has a final segment 11-14.
        let whisper = [
            TranscriptSegment(start: 0, end: 5, text: "first"),
            TranscriptSegment(start: 11, end: 14, text: "tail"),
        ]
        let diar = [
            DiarSegment(start: 0, end: 5, speaker: "Alice"),
            DiarSegment(start: 6, end: 10, speaker: "Bob"),
        ]
        let result = TranscriptFormatter.assignSpeakers(
            whisperSegments: whisper, diarSegments: diar
        )
        #expect(result[0].speaker == "Alice")
        // tail midpoint = 12.5, nearest diar segment end is Bob at t=10 (gap 2.5)
        // vs Alice ending at t=5 (gap 7.5) → Bob wins
        #expect(result[1].speaker == "Bob")
    }

    @Test("Segment before first diar interval snaps to first speaker")
    func leadingGapSnapsToFirstSpeaker() {
        let whisper = [TranscriptSegment(start: 0, end: 1, text: "early")]
        let diar = [DiarSegment(start: 2, end: 5, speaker: "Alice")]
        let result = TranscriptFormatter.assignSpeakers(
            whisperSegments: whisper, diarSegments: diar
        )
        // midpoint 0.5, nearest is Alice starting at 2 (gap 1.5) — only option
        #expect(result[0].speaker == "Alice")
    }

    @Test("Mid-conversation gap picks nearest diar segment")
    func midConversationGap() {
        // Diar: A covers 0-4, B covers 8-12. Gap 4-8. Whisper segment in gap.
        let whisper = [TranscriptSegment(start: 4, end: 8, text: "gap")]
        let diar = [
            DiarSegment(start: 0, end: 4, speaker: "A"),
            DiarSegment(start: 8, end: 12, speaker: "B"),
        ]
        let result = TranscriptFormatter.assignSpeakers(
            whisperSegments: whisper, diarSegments: diar
        )
        // midpoint = 6; distance to A (end=4) = 2, distance to B (start=8) = 2
        // equidistant — sorted order is A before B, so A wins (stable min)
        #expect(result[0].speaker == "A")
    }

    @Test("Midpoint containment works as nearest (distance = 0)")
    func midpointContainmentIsNearestDistance() {
        // Whisper segment 5-7, no overlap with diar segments.
        // Midpoint 6.0 is contained by diar 5.5-6.5 → distance 0 → wins.
        let whisper = [TranscriptSegment(start: 5, end: 7, text: "gap")]
        let diar = [
            DiarSegment(start: 0, end: 4, speaker: "X"),
            DiarSegment(start: 5.5, end: 6.5, speaker: "Y"),
        ]
        let result = TranscriptFormatter.assignSpeakers(
            whisperSegments: whisper, diarSegments: diar
        )
        #expect(result[0].speaker == "Y")
    }

    @Test("Unsorted diar input gives same result as sorted")
    func unsortedDiarInput() {
        let whisper = [TranscriptSegment(start: 11, end: 14, text: "tail")]
        let diarSorted = [
            DiarSegment(start: 0, end: 5, speaker: "Alice"),
            DiarSegment(start: 6, end: 10, speaker: "Bob"),
        ]
        let diarReversed = [
            DiarSegment(start: 6, end: 10, speaker: "Bob"),
            DiarSegment(start: 0, end: 5, speaker: "Alice"),
        ]
        let r1 = TranscriptFormatter.assignSpeakers(whisperSegments: whisper, diarSegments: diarSorted)
        let r2 = TranscriptFormatter.assignSpeakers(whisperSegments: whisper, diarSegments: diarReversed)
        #expect(r1[0].speaker == r2[0].speaker)
        #expect(r1[0].speaker == "Bob")
    }

    // MARK: - assignSpeakers: edge cases

    @Test("Empty diarization segments → all UNKNOWN")
    func emptyDiarization() {
        let whisper = [TranscriptSegment(start: 0, end: 5, text: "Solo")]
        let result = TranscriptFormatter.assignSpeakers(
            whisperSegments: whisper, diarSegments: []
        )
        #expect(result[0].speaker == "UNKNOWN")
    }

    @Test("Empty whisper segments → empty result")
    func emptyWhisper() {
        let diar = [DiarSegment(start: 0, end: 10, speaker: "A")]
        let result = TranscriptFormatter.assignSpeakers(
            whisperSegments: [], diarSegments: diar
        )
        #expect(result.isEmpty)
    }
}
