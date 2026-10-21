import Foundation
import Testing
@testable import TranscribeerCore

struct LanguageDetectorTests {
    @Test("summed confidence beats a single confident outlier")
    func tallyByConfidence() {
        let votes = [
            LanguageDetector.Vote(language: "he", confidence: 0.6),
            LanguageDetector.Vote(language: "he", confidence: 0.7),
            LanguageDetector.Vote(language: "en", confidence: 0.95),
        ]
        #expect(LanguageDetector.tally(votes) == "he")
    }

    @Test("no votes means no language")
    func tallyEmpty() {
        #expect(LanguageDetector.tally([]) == nil)
    }

    @Test("window starts", arguments: [
        (0.0, [Double]()),
        (20.0, [0.0]),
        (60.0, [0.0]),
        (600.0, [60.0, 240.0, 420.0]),
    ])
    func windowStarts(duration: Double, expected: [Double]) {
        #expect(LanguageDetector.windowStarts(duration: duration) == expected)
    }

    @Test("last window never runs past the end")
    func windowStartsClamped() {
        let duration = 61.0
        for start in LanguageDetector.windowStarts(duration: duration) {
            #expect(start + LanguageDetector.windowSeconds <= duration)
        }
    }
}
