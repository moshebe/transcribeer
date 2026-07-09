import Testing
@testable import TranscribeerApp

struct TextMatcherTests {
    @Test("Counts case-insensitive occurrences")
    func count() {
        #expect(TextMatcher.count(of: "the", in: "The theme is there") == 3)
        #expect(TextMatcher.count(of: "xyz", in: "nothing here") == 0)
        #expect(TextMatcher.count(of: "", in: "anything") == 0)
    }

    @Test("Overlapping matches advance past each occurrence")
    func nonOverlapping() {
        #expect(TextMatcher.count(of: "aa", in: "aaaa") == 2)
    }

    @Test("Highlights every match and accents the active one")
    func highlighted() {
        let attributed = TextMatcher.highlighted(text: "foo foo foo", query: "foo", activeOccurrence: 1)
        let highlighted = attributed.runs.filter { $0.backgroundColor != nil }
        #expect(highlighted.count == 3)
        let active = attributed.runs.filter { $0.backgroundColor == .orange }
        #expect(active.count == 1)
    }

    @Test("Empty query leaves text unstyled")
    func emptyQuery() {
        let attributed = TextMatcher.highlighted(text: "hello", query: "", activeOccurrence: nil)
        #expect(attributed.runs.allSatisfy { $0.backgroundColor == nil })
    }
}
