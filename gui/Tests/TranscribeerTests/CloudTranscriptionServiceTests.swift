import Foundation
import Testing
@testable import TranscribeerApp

/// Tests the JSON-shape contract for both cloud transcription backends.
///
/// We don't exercise URLSession here — the chunking + HTTP plumbing is plain
/// orchestration. What can drift between API releases is the response shape,
/// so the parsers get table-driven coverage.
struct CloudTranscriptionServiceTests {
    // MARK: - OpenAI

    @Test("OpenAI verbose_json: maps segments to TranscriptSegment")
    func openAIVerboseJSON() throws {
        let json = #"""
        {
            "text": "Hello world.",
            "duration": 4.2,
            "segments": [
                { "id": 0, "start": 0.0, "end": 2.1, "text": " Hello" },
                { "id": 1, "start": 2.1, "end": 4.2, "text": " world." }
            ]
        }
        """#
        let segments = try OpenAITranscription.parseResponse(Data(json.utf8))
        #expect(segments.count == 2)
        #expect(segments[0].start == 0.0)
        #expect(segments[0].end == 2.1)
        #expect(segments[0].text == " Hello")
        #expect(segments[1].text == " world.")
    }

    @Test("OpenAI fallback: text-only response becomes a single segment")
    func openAIFlatTextFallback() throws {
        // Some `gpt-4o-transcribe` calls return only `text` + `duration`
        // without segment-level timestamps. Without the fallback that chunk
        // would be silently dropped from the merged transcript.
        let json = #"""
        { "text": "the whole chunk in one breath", "duration": 12.5 }
        """#
        let segments = try OpenAITranscription.parseResponse(Data(json.utf8))
        #expect(segments.count == 1)
        #expect(segments[0].start == 0)
        #expect(segments[0].end == 12.5)
        #expect(segments[0].text == "the whole chunk in one breath")
    }

    @Test("OpenAI: empty response yields no segments instead of throwing")
    func openAIEmpty() throws {
        let json = #"{ "text": "", "duration": 0 }"#
        let segments = try OpenAITranscription.parseResponse(Data(json.utf8))
        #expect(segments.isEmpty)
    }

    @Test("OpenAI: malformed JSON throws invalidResponse")
    func openAIBadJSON() {
        let bytes = Data("not json".utf8)
        #expect(throws: TranscriptionError.self) {
            try OpenAITranscription.parseResponse(bytes)
        }
    }

    // MARK: - Gemini

    @Test("Gemini: structured JSON output is decoded into segments")
    func geminiStructured() throws {
        // Gemini wraps the structured-output JSON payload as a string inside
        // a candidate part; the parser must unwrap the envelope and re-decode
        // the inner string. We build the whole shape via JSONSerialization
        // so the test fixture stays in sync with whatever escaping rules
        // JSONSerialization produces.
        let inner = #"[{"start":0.0,"end":2.0,"text":"hi"},{"start":2.0,"end":3.5,"text":"there"}]"#
        let envelope: [String: Any] = [
            "candidates": [["content": ["parts": [["text": inner]]]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let segments = try GeminiTranscription.parseResponse(data)
        #expect(segments.count == 2)
        #expect(segments[0].text == "hi")
        #expect(segments[1].start == 2.0)
        #expect(segments[1].end == 3.5)
    }

    @Test("Gemini: empty candidates raises invalidResponse with a clear hint")
    func geminiEmpty() {
        let envelope = #"{ "candidates": [] }"#
        #expect(throws: TranscriptionError.self) {
            try GeminiTranscription.parseResponse(Data(envelope.utf8))
        }
    }

    @Test("Gemini: malformed inner JSON raises invalidResponse")
    func geminiBadInner() throws {
        let envelope: [String: Any] = [
            "candidates": [["content": ["parts": [["text": "not really json"]]]]],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        #expect(throws: TranscriptionError.self) {
            try GeminiTranscription.parseResponse(data)
        }
    }
}

/// Behavioural tests for the smooth-progress tracker. We can't easily test
/// the 4 Hz heartbeat without making the suite slow and flaky, but we can
/// verify the three properties the bar visually depends on: starts at 0,
/// ends at 1, and in-flight chunks contribute a fractional value.
struct CloudProgressTrackerTests {
    /// Captures every snapshot the tracker emits so we can assert on the
    /// terminal value, monotonicity, and the count fields. `@unchecked
    /// Sendable` because the emit closure is `@Sendable` and our lock
    /// guards access — same pattern as the tracker itself.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [CloudProgressTracker.Snapshot] = []

        func append(_ value: CloudProgressTracker.Snapshot) {
            lock.withLock { values.append(value) }
        }

        var snapshots: [CloudProgressTracker.Snapshot] { lock.withLock { values } }
        var fractions: [Double] { snapshots.map(\.fraction) }
    }

    @Test("pending chunks: no emit before start/markStarted is called")
    func pendingChunksEmitNothing() {
        let sink = Sink()
        // No start(), no markStarted — nothing should fire.
        _ = CloudProgressTracker(
            total: 4, audioSecondsPerChunk: 600, emit: { sink.append($0) }
        )
        #expect(sink.snapshots.isEmpty)
    }

    @Test("markCompleted on every chunk lands on 1.0")
    func allCompletedReachesOne() throws {
        let sink = Sink()
        let tracker = CloudProgressTracker(
            total: 3, audioSecondsPerChunk: 600, emit: { sink.append($0) }
        )
        for i in 0..<3 {
            tracker.markStarted(i)
            tracker.markCompleted(i)
        }
        let last = try #require(sink.snapshots.last)
        #expect(last.fraction == 1.0)
        #expect(last.completed == 3)
        #expect(last.inFlight == 0)
        #expect(last.total == 3)
    }

    @Test("stop() force-emits the final snapshot even with no completions")
    func stopForcesFinalValue() throws {
        let sink = Sink()
        let tracker = CloudProgressTracker(
            total: 2, audioSecondsPerChunk: 600, emit: { sink.append($0) }
        )
        tracker.stop()
        let last = try #require(sink.snapshots.last)
        #expect(last.fraction == 1.0)
        #expect(last.completed == 2)
        #expect(last.total == 2)
    }

    @Test("snapshot counts move as chunks transition through the lifecycle")
    func snapshotCountsTrackLifecycle() throws {
        let sink = Sink()
        let tracker = CloudProgressTracker(
            total: 3, audioSecondsPerChunk: 600, emit: { sink.append($0) }
        )
        tracker.markStarted(0)
        let afterFirstStart = try #require(sink.snapshots.last)
        #expect(afterFirstStart.inFlight == 1)
        #expect(afterFirstStart.completed == 0)

        tracker.markStarted(1)
        let afterSecondStart = try #require(sink.snapshots.last)
        #expect(afterSecondStart.inFlight == 2)

        tracker.markCompleted(0)
        let afterFirstDone = try #require(sink.snapshots.last)
        #expect(afterFirstDone.completed == 1)
        #expect(afterFirstDone.inFlight == 1)

        tracker.markCompleted(1)
        tracker.markStarted(2)
        tracker.markCompleted(2)
        let final = try #require(sink.snapshots.last)
        #expect(final.completed == 3)
        #expect(final.inFlight == 0)
    }

    @Test("emitted fraction is monotonic across the chunk lifecycle")
    func monotonicEmissions() {
        let sink = Sink()
        let tracker = CloudProgressTracker(
            total: 4, audioSecondsPerChunk: 600, emit: { sink.append($0) }
        )
        for i in 0..<4 {
            tracker.markStarted(i)
            tracker.markCompleted(i)
        }

        let values = sink.fractions
        #expect(!values.isEmpty)
        for (a, b) in zip(values, values.dropFirst()) {
            #expect(a <= b, "progress regressed: \(a) -> \(b)")
        }
        #expect(values.last == 1.0)
    }

    @Test("in-flight chunks contribute a fraction below 1.0")
    func inFlightContributesFraction() async throws {
        let sink = Sink()
        // 10 s bootstrap mean (audioSecondsPerChunk=100, factor 10) so a
        // ~50 ms sleep is a measurable fraction without making the test
        // slow. We don't drive the heartbeat — we call tick implicitly via
        // markStarted, then again via a second markStarted on another
        // chunk to force a recompute after the sleep.
        let tracker = CloudProgressTracker(
            total: 2, audioSecondsPerChunk: 100, emit: { sink.append($0) }
        )
        tracker.markStarted(0)
        try await Task.sleep(nanoseconds: 50_000_000)  // 50 ms
        tracker.markStarted(1)  // forces another tick; both chunks in-flight

        let latest = try #require(sink.snapshots.last)
        #expect(latest.fraction > 0, "in-flight chunks should produce >0 progress")
        #expect(latest.fraction < 1.0, "in-flight estimate must not reach 1.0")
        #expect(latest.inFlight == 2)
    }
}
