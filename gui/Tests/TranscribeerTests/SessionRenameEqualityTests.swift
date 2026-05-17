import Foundation
import Testing
@testable import TranscribeerApp

/// Reproduces the sidebar bug: updating a session's displayed fields
/// (name, duration after a trim/split, artifact flags, …) doesn't refresh
/// the sidebar row. Root cause is `Session`'s custom `==` which compares
/// only `id` (the directory path). SwiftUI uses Equatable to diff View
/// properties, so `SessionRow(session:)` is memoized against the stale
/// value and never re-renders with the new content.
struct SessionRenameEqualityTests {
    @Test("Renamed session must not compare equal to its pre-rename value")
    func renamePropagatesThroughEquatable() throws {
        let dir = try makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let beforeRename = SessionManager.sessionRow(dir)
        #expect(beforeRename.isUntitled)

        SessionManager.setName(dir, "Q1 planning")
        let afterRename = SessionManager.sessionRow(dir)

        #expect(afterRename.name == "Q1 planning")
        // If these compare equal, SwiftUI skips re-rendering the sidebar
        // row and the old name sticks on screen even though meta.json was
        // updated and the parent reloaded the sessions list.
        #expect(beforeRename != afterRename)
    }

    @Test("Sessions differing only in duration must not compare equal")
    func durationChangePropagatesThroughEquatable() {
        // Trimming/splitting a clip rewrites the audio file and produces a
        // new `duration` string, while the directory path (id) stays the
        // same. The sidebar's date-line renders this duration, so equality
        // must reflect the change or the trimmed clip shows its pre-trim
        // runtime until the user selects another row and comes back.
        let path = URL(fileURLWithPath: "/tmp/transcribeer-fake-session")
        let before = makeSession(path: path, duration: "12:34")
        let after = makeSession(path: path, duration: "5:00")

        #expect(before != after)
    }

    // MARK: - Fixtures

    private func makeSession(path: URL, duration: String) -> Session {
        Session(
            id: path.path,
            path: path,
            name: "Recording",
            isUntitled: false,
            date: Date(timeIntervalSince1970: 1_750_000_000),
            formattedDate: "",
            duration: duration,
            snippet: "",
            language: nil,
            hasAudio: true,
            hasTranscript: false,
            hasSummary: false,
            startedAt: nil,
            endedAt: nil,
        )
    }

    private func makeSessionDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribeer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
        )
        return base
    }
}
