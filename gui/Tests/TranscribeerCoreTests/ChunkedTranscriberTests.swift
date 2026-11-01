import Foundation
import Testing
@testable import TranscribeerCore

struct ChunkedTranscriberTests {
    @Test
    func mergeEmptyChunksReturnsEmpty() throws {
        let result = ChunkedTranscriber.mergeChunkResults([])
        #expect(result.isEmpty)
    }

    @Test
    func mergeSingleChunkPreservesSegments() throws {
        let segs = [
            TranscriptSegment(start: 0, end: 1, text: "Hello"),
            TranscriptSegment(start: 1, end: 2, text: "world"),
        ]
        let result = ChunkedTranscriber.mergeChunkResults([(offset: 0, segments: segs)])
        try #require(result.count == 2)
        #expect(result[0].text == "Hello")
        #expect(result[0].start == 0.0)
        #expect(result[1].start == 1.0)
    }

    @Test
    func mergeAppliesOffsetToTimestamps() throws {
        let segs = [TranscriptSegment(start: 0.5, end: 1.0, text: "First")]
        let result = ChunkedTranscriber.mergeChunkResults([(offset: 600, segments: segs)])
        #expect(abs(result[0].start - 600.5) < 0.001)
        #expect(abs(result[0].end - 601.0) < 0.001)
    }

    @Test
    func mergeMultipleChunksSortedByStart() throws {
        let chunk0 = (offset: 0.0, segments: [TranscriptSegment(start: 5, end: 10, text: "A")])
        let chunk1 = (offset: 600.0, segments: [TranscriptSegment(start: 2, end: 4, text: "B")])
        let result = ChunkedTranscriber.mergeChunkResults([chunk1, chunk0])
        try #require(result.count == 2)
        #expect(result[0].text == "A")  // start = 5
        #expect(result[1].text == "B")  // start = 602
    }

    @Test
    func mergeFiltersEmptyText() throws {
        let segs = [
            TranscriptSegment(start: 0, end: 1, text: "   "),
            TranscriptSegment(start: 1, end: 2, text: "Hello"),
            TranscriptSegment(start: 2, end: 3, text: ""),
        ]
        let result = ChunkedTranscriber.mergeChunkResults([(offset: 0, segments: segs)])
        try #require(result.count == 1)
        #expect(result[0].text == "Hello")
    }
}
