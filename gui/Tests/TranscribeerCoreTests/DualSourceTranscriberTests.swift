import Foundation
import Testing
@testable import TranscribeerCore

struct DualSourceTranscriberTests {
    // MARK: - mergeAndTag

    @Test("Mic-only segments are all tagged self")
    func micOnly() {
        let mic = [
            TranscriptSegment(start: 0, end: 2, text: "Hello"),
            TranscriptSegment(start: 3, end: 5, text: "World"),
        ]
        let result = DualSourceTranscriber.mergeAndTag(
            micSegments: mic,
            sysSegments: nil,
            timing: .init(micStartEpoch: 0, sysStartEpoch: nil),
            selfLabel: "You",
            otherLabel: "Them"
        )
        #expect(result.count == 2)
        #expect(result.allSatisfy { $0.speaker == "You" })
        #expect(result[0].start == 0)
        #expect(result[1].start == 3)
    }

    @Test("Mic-only with non-zero epoch applies offset")
    func micOnlyOffset() {
        let mic = [TranscriptSegment(start: 0, end: 1, text: "Hey")]
        let result = DualSourceTranscriber.mergeAndTag(
            micSegments: mic,
            sysSegments: nil,
            timing: .init(micStartEpoch: 5, sysStartEpoch: nil),
            selfLabel: "You",
            otherLabel: "Them"
        )
        // sessionStart = min(5, 0) = 0; micOffset = 5
        #expect(result[0].start == 5)
    }

    @Test("Sys-only segments are all tagged other")
    func sysOnly() {
        let sys = [
            TranscriptSegment(start: 0, end: 2, text: "Hi there"),
        ]
        let result = DualSourceTranscriber.mergeAndTag(
            micSegments: nil,
            sysSegments: sys,
            timing: .init(micStartEpoch: nil, sysStartEpoch: 20),
            selfLabel: "You",
            otherLabel: "Them"
        )
        #expect(result.count == 1)
        #expect(result[0].speaker == "Them")
    }

    @Test("Mic starts later than sys: sys gets zero offset, mic is shifted forward")
    func micLaterOffset() {
        let mic = [TranscriptSegment(start: 0, end: 1, text: "A")]
        let sys = [TranscriptSegment(start: 0, end: 1, text: "B")]
        // mic starts at t=5, sys starts at t=3 → sessionStart = 3
        // micOffset = 2, sysOffset = 0
        let result = DualSourceTranscriber.mergeAndTag(
            micSegments: mic,
            sysSegments: sys,
            timing: .init(micStartEpoch: 5, sysStartEpoch: 3),
            selfLabel: "You",
            otherLabel: "Them"
        )
        #expect(result.count == 2)
        let micSeg = result.first { $0.speaker == "You" }
        let sysSeg = result.first { $0.speaker == "Them" }
        #expect(micSeg?.start == 2)
        #expect(sysSeg?.start == 0)
    }

    @Test("Sys starts later than mic: mic gets zero offset, sys is shifted forward")
    func sysLaterOffset() {
        let mic = [TranscriptSegment(start: 0, end: 1, text: "A")]
        let sys = [TranscriptSegment(start: 0, end: 1, text: "B")]
        // mic starts at t=2, sys starts at t=7 → sessionStart = 2
        // micOffset = 0, sysOffset = 5
        let result = DualSourceTranscriber.mergeAndTag(
            micSegments: mic,
            sysSegments: sys,
            timing: .init(micStartEpoch: 2, sysStartEpoch: 7),
            selfLabel: "You",
            otherLabel: "Them"
        )
        let micSeg = result.first { $0.speaker == "You" }
        let sysSeg = result.first { $0.speaker == "Them" }
        #expect(micSeg?.start == 0)
        #expect(sysSeg?.start == 5)
    }

    @Test("Interleave sorts by start time")
    func interleaveByStart() {
        let mic = [
            TranscriptSegment(start: 5, end: 6, text: "mic late"),
        ]
        let sys = [
            TranscriptSegment(start: 1, end: 2, text: "sys early"),
        ]
        let result = DualSourceTranscriber.mergeAndTag(
            micSegments: mic,
            sysSegments: sys,
            timing: .init(micStartEpoch: 0, sysStartEpoch: 0),
            selfLabel: "You",
            otherLabel: "Them"
        )
        #expect(result.map(\.speaker) == ["Them", "You"])
    }

    @Test("Tie on start time prefers mic (self) first")
    func tiePrefersMic() {
        let mic = [TranscriptSegment(start: 1, end: 2, text: "mic")]
        let sys = [TranscriptSegment(start: 1, end: 2, text: "sys")]
        let result = DualSourceTranscriber.mergeAndTag(
            micSegments: mic,
            sysSegments: sys,
            timing: .init(micStartEpoch: 0, sysStartEpoch: 0),
            selfLabel: "You",
            otherLabel: "Them"
        )
        #expect(result.map(\.speaker) == ["You", "Them"])
    }

    @Test("Missing timing defaults to epoch 0 for both streams")
    func missingTimingDefaultsToZero() {
        let mic = [TranscriptSegment(start: 2, end: 3, text: "A")]
        let sys = [TranscriptSegment(start: 1, end: 2, text: "B")]
        let result = DualSourceTranscriber.mergeAndTag(
            micSegments: mic,
            sysSegments: sys,
            timing: .init(micStartEpoch: nil, sysStartEpoch: nil),
            selfLabel: "You",
            otherLabel: "Them"
        )
        #expect(result.count == 2)
        // No offset applied since both default to 0.
        #expect(result.map(\.start) == [1, 2])
    }

    // MARK: - formatDual

    @Test("formatDual merges consecutive same-speaker lines")
    func formatDualMergesConsecutive() {
        let segments = [
            LabeledSegment(start: 0, end: 2, speaker: "You", text: "Hello"),
            LabeledSegment(start: 2, end: 4, speaker: "You", text: "world"),
            LabeledSegment(start: 5, end: 7, speaker: "Them", text: "Hi"),
        ]
        let formatted = TranscriptFormatter.formatDual(segments)
        #expect(formatted.contains("[00:00 -> 00:04] You: Hello world"))
        #expect(formatted.contains("[00:05 -> 00:07] Them: Hi"))
    }

    @Test("formatDual uses configured labels directly")
    func formatDualUsesCustomLabels() {
        let segments = [
            LabeledSegment(start: 0, end: 1, speaker: "Alice", text: "Hey"),
            LabeledSegment(start: 1, end: 2, speaker: "Bob", text: "Yo"),
        ]
        let formatted = TranscriptFormatter.formatDual(segments)
        #expect(formatted.contains("Alice:"))
        #expect(formatted.contains("Bob:"))
    }

    @Test("Empty segments produce empty string")
    func formatDualEmpty() {
        #expect(TranscriptFormatter.formatDual([]).isEmpty)
    }

    // MARK: - Diarization invocation

    @Test("Diarization respects the mic-multiuser config flag")
    func diarizationRespectsConfigFlag() async throws {
        let originalDiarize = DualSourceTranscriber.diarizeFunc
        let originalTranscribe = DualSourceTranscriber.transcribeChunkFunc
        let originalAudible = DualSourceTranscriber.ensureAudibleFunc
        defer {
            DualSourceTranscriber.diarizeFunc = originalDiarize
            DualSourceTranscriber.transcribeChunkFunc = originalTranscribe
            DualSourceTranscriber.ensureAudibleFunc = originalAudible
        }

        DualSourceTranscriber.transcribeChunkFunc = { _, _, _, _, _, _, _ in
            [
                TranscriptSegment(start: 0, end: 0.4, text: "hello"),
                TranscriptSegment(start: 0.6, end: 1, text: "world"),
            ]
        }
        DualSourceTranscriber.ensureAudibleFunc = { _ in }

        // 1. Disabled — diarization should not be called.
        var wasCalled = false
        DualSourceTranscriber.diarizeFunc = { _, _ in
            wasCalled = true
            return []
        }
        var cfg = AppConfig()
        cfg.audio.diarizeMicMultiuser = false

        _ = try await DualSourceTranscriber.transcribeDual(
            mic: URL(fileURLWithPath: "/tmp/mic.caf"),
            sys: nil,
            timing: .init(micStartEpoch: 0, sysStartEpoch: nil),
            cfg: cfg,
            progress: .init(mic: nil, sys: nil)
        )
        #expect(!wasCalled)

        // 2. Enabled — diarization should be called on mic only.
        var calledURL: URL?
        DualSourceTranscriber.diarizeFunc = { url, _ in
            calledURL = url
            return [
                DiarSegment(start: 0, end: 0.5, speaker: "Speaker 1"),
                DiarSegment(start: 0.5, end: 1, speaker: "Speaker 2"),
            ]
        }
        cfg.audio.diarizeMicMultiuser = true
        cfg.audio.selfLabel = "You"
        cfg.audio.otherLabel = "Them"

        let micURL = URL(fileURLWithPath: "/tmp/mic.caf")
        let result = try await DualSourceTranscriber.transcribeDual(
            mic: micURL,
            sys: nil,
            timing: .init(micStartEpoch: 0, sysStartEpoch: nil),
            cfg: cfg,
            progress: .init(mic: nil, sys: nil)
        )
        #expect(calledURL == micURL)
        #expect(result.count == 2)
        #expect(result[0].speaker == "Speaker 1")
        #expect(result[1].speaker == "Speaker 2")

        // 3. Interleave with sys — diarized mic + sys together.
        DualSourceTranscriber.diarizeFunc = { _, _ in
            [DiarSegment(start: 0, end: 2, speaker: "Alice")]
        }
        DualSourceTranscriber.transcribeChunkFunc = { url, _, _, _, _, _, _ in
            if url.path.contains("mic") {
                return [TranscriptSegment(start: 0, end: 2, text: "hello")]
            }
            return [TranscriptSegment(start: 1, end: 3, text: "hi")]
        }

        let interleaved = try await DualSourceTranscriber.transcribeDual(
            mic: URL(fileURLWithPath: "/tmp/mic.caf"),
            sys: URL(fileURLWithPath: "/tmp/sys.caf"),
            timing: .init(micStartEpoch: 0, sysStartEpoch: 0),
            cfg: cfg,
            progress: .init(mic: nil, sys: nil)
        )
        #expect(interleaved.count == 2)
        #expect(interleaved[0].speaker == "Alice")
        #expect(interleaved[0].text == "hello")
        #expect(interleaved[1].speaker == "Them")
        #expect(interleaved[1].text == "hi")
    }
}
