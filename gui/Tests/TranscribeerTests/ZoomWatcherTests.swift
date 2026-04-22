import Testing
@testable import TranscribeerApp

@MainActor
struct ZoomWatcherTests {
    @Test("cleanZoomTitle returns nil for home/untitled/empty", arguments: [
        "",
        "   ",
        "Zoom",
        "zoom",
        "Zoom Workplace",
        "Zoom Meeting",
        "zoom meeting",
        "Zoom - Zoom",
    ])
    func cleanTitleGeneric(input: String) {
        #expect(ZoomWatcher.cleanZoomTitle(input) == nil)
    }

    @Test("cleanZoomTitle strips Zoom suffix and returns topic", arguments: [
        ("Team Standup - Zoom", "Team Standup"),
        ("Quarterly Review | Zoom", "Quarterly Review"),
        ("1:1 with Alice — Zoom", "1:1 with Alice"),
        ("Board – Zoom", "Board"),
        ("Team Standup", "Team Standup"),
    ])
    func cleanTitleTopic(pair: (String, String)) {
        #expect(ZoomWatcher.cleanZoomTitle(pair.0) == pair.1)
    }
}
