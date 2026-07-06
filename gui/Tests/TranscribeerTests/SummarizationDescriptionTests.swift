import Testing
@testable import TranscribeerApp

/// Locks down the behaviour of `SummarizationService.sanitizeOneSentence`:
/// the sidebar shows this string verbatim, so leading markdown markers,
/// surrounding quotes, and stray prefixes like "Summary:" must be stripped
/// regardless of how the LLM decides to wrap its reply.
@Suite("Summarization description sanitizer")
struct SummarizationDescriptionTests {
    @Test(arguments: [
        (
            "Plain sentence stays intact",
            "Kostya and Guy discussed the new sidebar description feature.",
            "Kostya and Guy discussed the new sidebar description feature.",
        ),
        (
            "Wrapping double quotes are removed",
            "\"Team aligned on shipping the menu redesign next week.\"",
            "Team aligned on shipping the menu redesign next week.",
        ),
        (
            "Single quotes are removed",
            "'Decided to ship Friday.'",
            "Decided to ship Friday.",
        ),
        (
            "Leading markdown heading marker dropped",
            "## Sync on hiring loop for staff engineer role.",
            "Sync on hiring loop for staff engineer role.",
        ),
        (
            "Leading bullet dropped",
            "- Reviewed Q3 roadmap and dropped two stretch goals.",
            "Reviewed Q3 roadmap and dropped two stretch goals.",
        ),
        (
            "Leading 'Summary:' label dropped",
            "Summary: Catch-up on calendar integration progress.",
            "Catch-up on calendar integration progress.",
        ),
        (
            "Leading 'Description:' label dropped",
            "Description: Customer interview about onboarding pains.",
            "Customer interview about onboarding pains.",
        ),
        (
            "Multi-line replies collapse to a single line",
            "First line of the answer\nsecond line continues",
            "First line of the answer second line continues",
        ),
        (
            "Surrounding whitespace and asterisks stripped",
            "  **Decision made to pause the migration.**  ",
            "Decision made to pause the migration.",
        ),
        ("Empty string returns empty", "", ""),
        ("Whitespace-only returns empty", "   \n   ", ""),
    ])
    func sanitize(name: String, input: String, expected: String) {
        #expect(SummarizationService.sanitizeOneSentence(input) == expected, "\(name)")
    }
}
