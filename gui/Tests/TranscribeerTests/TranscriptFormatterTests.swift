import Testing
import TranscribeerCore
@testable import TranscribeerApp

struct TranscriptFormatterTests {
    // MARK: - formatTimestamp

    @Test("Formats seconds as MM:SS",
          arguments: [
              (0.0, "00:00"),
              (5.0, "00:05"),
              (65.0, "01:05"),
              (3661.0, "61:01"),
          ])
    func formatTimestamp(input: Double, expected: String) {
        #expect(TranscriptFormatter.formatTimestamp(input) == expected)
    }

    @Test("Fractional seconds are truncated, not rounded")
    func fractionalSecondsFloor() {
        #expect(TranscriptFormatter.formatTimestamp(59.9) == "00:59")
        #expect(TranscriptFormatter.formatTimestamp(0.999) == "00:00")
    }

    // MARK: - sanitize

    @Test("sanitize strips Whisper special tokens")
    func sanitizeStripsSpecialTokens() {
        let dirty = "<|startoftranscript|><|he|><|transcribe|><|0.00|> hello<|15.60|><|endoftext|>"
        #expect(TranscriptFormatter.sanitize(dirty) == "hello")
    }

    @Test("sanitize collapses whitespace and trims")
    func sanitizeCollapsesWhitespace() {
        #expect(TranscriptFormatter.sanitize("  foo   bar  \t baz  ") == "foo bar baz")
    }

    @Test("sanitize preserves normal text")
    func sanitizeLeavesCleanText() {
        #expect(TranscriptFormatter.sanitize("Hello world") == "Hello world")
        #expect(TranscriptFormatter.sanitize("").isEmpty)
    }

    // MARK: - parse

    @Test("parse reads formatted transcript output")
    func parseRoundTrip() {
        let formatted = """
        [00:00 -> 00:30] Speaker 1: First line
        [00:30 -> 01:05] Speaker 2: Second line
        """
        let lines = TranscriptFormatter.parse(formatted)
        #expect(lines.count == 2)
        #expect(lines[0].start == 0)
        #expect(lines[0].end == 30)
        #expect(lines[0].speaker == "Speaker 1")
        #expect(lines[0].text == "First line")
        #expect(lines[1].start == 30)
        #expect(lines[1].end == 65)
        #expect(lines[1].speaker == "Speaker 2")
    }

    @Test("parse strips special tokens from legacy transcripts")
    func parseCleansLegacyTokens() {
        let dirty = "[01:05 -> 03:12] Speaker 1: <|startoftranscript|><|he|><|0.00|> נאום<|15.60|><|endoftext|>"
        let lines = TranscriptFormatter.parse(dirty)
        #expect(lines.count == 1)
        #expect(lines[0].start == 65)
        #expect(lines[0].end == 3 * 60 + 12)
        #expect(lines[0].speaker == "Speaker 1")
        #expect(lines[0].text == "נאום")
    }

    @Test("parse supports HH:MM:SS timestamps")
    func parseLongTimestamps() {
        let input = "[1:02:03 -> 1:02:30] Speaker 1: hi"
        let lines = TranscriptFormatter.parse(input)
        #expect(lines.count == 1)
        #expect(lines[0].start == 3723)
        #expect(lines[0].end == 3750)
    }

    @Test("parse folds continuation lines into the previous row")
    func parseFoldsContinuations() {
        let input = """
        [00:00 -> 00:05] Speaker 1: first
        continued text
        [00:05 -> 00:10] Speaker 2: reply
        """
        let lines = TranscriptFormatter.parse(input)
        #expect(lines.count == 2)
        #expect(lines[0].text == "first continued text")
        #expect(lines[1].text == "reply")
    }

    @Test("parse empty input → empty result")
    func parseEmpty() {
        #expect(TranscriptFormatter.parse("").isEmpty)
        #expect(TranscriptFormatter.parse("   \n  ").isEmpty)
    }

    // MARK: - RTL detection

    @Test("RTL detection flags Hebrew text")
    func rtlDetectsHebrew() {
        #expect(TextDirection.containsRightToLeft("שלום עולם"))
    }

    @Test("RTL detection flags Arabic text")
    func rtlDetectsArabic() {
        #expect(TextDirection.containsRightToLeft("مرحبا بالعالم"))
    }

    @Test("RTL detection is false for English")
    func rtlFalseForEnglish() {
        #expect(!TextDirection.containsRightToLeft("Hello world"))
    }

    @Test("RTL detection flips on any RTL character (Latin majority is ignored)")
    func rtlAnyHebrewWins() {
        // Hebrew-majority technical prose → RTL.
        #expect(TextDirection.containsRightToLeft("זה הבדיקה של DataDog ו-PagerDuty במערכת"))
        // Latin-majority prose with a single Hebrew word → still RTL.
        // Policy: any Hebrew/Arabic glyph flips the document.
        #expect(TextDirection.containsRightToLeft("Discussing the שלום incident in production today"))
    }

    @Test("RTL detection handles empty and punctuation-only strings")
    func rtlHandlesEmpty() {
        #expect(!TextDirection.containsRightToLeft(""))
        #expect(!TextDirection.containsRightToLeft("... 12:34 !!!"))
    }
}
