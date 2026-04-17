import XCTest
@testable import TranscribeerCore

final class ChunkedTranscriberTests: XCTestCase {

    func testMergeEmptyChunksReturnsEmpty() {
        let result = ChunkedTranscriber.mergeChunkResults([])
        XCTAssertTrue(result.isEmpty)
    }

    func testMergeSingleChunkPreservesSegments() {
        let segs = [
            TranscriptSegment(start: 0, end: 1, text: "Hello"),
            TranscriptSegment(start: 1, end: 2, text: "world"),
        ]
        let result = ChunkedTranscriber.mergeChunkResults([(offset: 0, segments: segs)])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, "Hello")
        XCTAssertEqual(result[0].start, 0.0)
        XCTAssertEqual(result[1].start, 1.0)
    }

    func testMergeAppliesOffsetToTimestamps() {
        let segs = [TranscriptSegment(start: 0.5, end: 1.0, text: "First")]
        let result = ChunkedTranscriber.mergeChunkResults([(offset: 600, segments: segs)])
        XCTAssertEqual(result[0].start, 600.5, accuracy: 0.001)
        XCTAssertEqual(result[0].end, 601.0, accuracy: 0.001)
    }

    func testMergeMultipleChunksSortedByStart() {
        let chunk0 = (offset: 0.0,   segments: [TranscriptSegment(start: 5, end: 10, text: "A")])
        let chunk1 = (offset: 600.0, segments: [TranscriptSegment(start: 2, end: 4,  text: "B")])
        let result = ChunkedTranscriber.mergeChunkResults([chunk0, chunk1])
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, "A")  // start = 5
        XCTAssertEqual(result[1].text, "B")  // start = 602
    }

    func testMergeFiltersEmptyText() {
        let segs = [
            TranscriptSegment(start: 0, end: 1, text: "   "),
            TranscriptSegment(start: 1, end: 2, text: "Hello"),
            TranscriptSegment(start: 2, end: 3, text: ""),
        ]
        let result = ChunkedTranscriber.mergeChunkResults([(offset: 0, segments: segs)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "Hello")
    }
}
