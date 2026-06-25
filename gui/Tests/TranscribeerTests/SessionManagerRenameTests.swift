import Foundation
import Testing
@testable import TranscribeerApp

/// Tests for `SessionManager` name-management functions: `setName`, `displayName`,
/// `sessionRow`, and `sessionDetail`.
///
/// These cover the pure disk I/O layer that underpins the session-rename UI. The
/// bug that prompted this suite (commit 5a64318) was a cross-session state leak:
/// switching from Session B back to Session A caused `flushRename` to write B's
/// local name into A's `meta.json` because the `onRename` closure had already
/// been rebuilt with A as its captured session while the local `name` state still
/// held B's value. Tests here verify that `setName` is isolated — writes to one
/// session never affect another.
struct SessionManagerRenameTests {
    // MARK: - Helpers

    private static func makeSessionDir(prefix: String = "rename") throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribeer-\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: - setName / sessionDetail round-trip

    @Test("setName persists and is readable via sessionDetail",
          .bug(id: "5a64318", "debounce commit introduced stale detail.name"))
    func setNameRoundTripsThroughSessionDetail() throws {
        let dir = try Self.makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        SessionManager.setName(dir, "Q1 planning")

        let detail = SessionManager.sessionDetail(dir)
        #expect(detail.name == "Q1 planning", "sessionDetail should return the name written by setName")
    }

    @Test("setName persists and is readable via sessionRow")
    func setNameRoundTripsThroughSessionRow() throws {
        let dir = try Self.makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(SessionManager.sessionRow(dir).isUntitled, "fresh dir should start untitled")

        SessionManager.setName(dir, "Sprint review")
        let row = SessionManager.sessionRow(dir)

        #expect(row.name == "Sprint review")
        #expect(row.isUntitled == false, "after setName the row must no longer be untitled")
    }

    // MARK: - Metadata isolation

    @Test("setName preserves other meta fields (notes)")
    func setNamePreservesNotes() throws {
        let dir = try Self.makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed a notes field the same way the app does.
        SessionManager.setNotes(dir, "Important context")
        SessionManager.setName(dir, "Retro session")

        let detail = SessionManager.sessionDetail(dir)
        #expect(detail.name == "Retro session")
        #expect(detail.notes == "Important context", "setName must not clobber other meta fields")
    }

    @Test("setNotes preserves name")
    func setNotesPreservesName() throws {
        let dir = try Self.makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        SessionManager.setName(dir, "Architecture review")
        SessionManager.setNotes(dir, "Discussion summary")

        let detail = SessionManager.sessionDetail(dir)
        #expect(detail.name == "Architecture review", "setNotes must not clobber the session name")
        #expect(detail.notes == "Discussion summary")
    }

    // MARK: - displayName fallback

    @Test("displayName falls back to directory name when meta has no name")
    func displayNameFallsBackToDirName() throws {
        let dir = try Self.makeSessionDir(prefix: "fallback-session")
        defer { try? FileManager.default.removeItem(at: dir) }

        // No name written — meta.json may not even exist.
        let display = SessionManager.displayName(dir)
        #expect(display == dir.lastPathComponent, "displayName should fall back to the directory name")
    }

    @Test("displayName returns stored name when present")
    func displayNameReturnsStoredName() throws {
        let dir = try Self.makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        SessionManager.setName(dir, "Team sync")
        #expect(SessionManager.displayName(dir) == "Team sync")
    }

    @Test("setName with empty string makes session untitled again")
    func setNameEmptyStringMakesSessionUntitled() throws {
        let dir = try Self.makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        SessionManager.setName(dir, "Temporary name")
        #expect(SessionManager.sessionRow(dir).isUntitled == false)

        SessionManager.setName(dir, "")
        let row = SessionManager.sessionRow(dir)
        #expect(row.isUntitled, "clearing the name should make the session untitled")
        #expect(
            row.name == dir.lastPathComponent,
            "untitled sessions should display their directory name"
        )
    }

    // MARK: - Multiple renames

    @Test("sessionDetail reflects the latest name after multiple renames")
    func latestRenameWins() throws {
        let dir = try Self.makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        SessionManager.setName(dir, "Draft A")
        SessionManager.setName(dir, "Draft B")
        SessionManager.setName(dir, "Final")

        #expect(SessionManager.sessionDetail(dir).name == "Final")
        #expect(SessionManager.sessionRow(dir).name == "Final")
    }

    // MARK: - Cross-session isolation

    /// This is the closest pure-logic equivalent to the UI bug: verifies that
    /// `setName` for one session directory never affects another. The UI bug
    /// occurred because `flushRename` called `onRename(name)` where `name` held
    /// the *outgoing* session's local edit but the `onRename` closure already
    /// captured the *incoming* session path.
    @Test(
        "Renaming two sessions independently leaves each with its own name",
        .bug(id: "5a64318", "cross-session state leak via flushRename")
    )
    func twoSessionsRemainsIndependent() throws {
        let dirA = try Self.makeSessionDir(prefix: "session-a")
        let dirB = try Self.makeSessionDir(prefix: "session-b")
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        SessionManager.setName(dirA, "Alpha")
        SessionManager.setName(dirB, "Beta")

        #expect(SessionManager.sessionDetail(dirA).name == "Alpha", "A must keep its own name")
        #expect(SessionManager.sessionDetail(dirB).name == "Beta", "B must keep its own name")
        #expect(SessionManager.displayName(dirA) == "Alpha")
        #expect(SessionManager.displayName(dirB) == "Beta")
    }

    @Test("Writing B's name to A's directory does not affect B")
    func writingWrongNameToADoesNotAffectB() throws {
        let dirA = try Self.makeSessionDir(prefix: "session-a")
        let dirB = try Self.makeSessionDir(prefix: "session-b")
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        SessionManager.setName(dirA, "Or")
        SessionManager.setName(dirB, "Vasi")

        // Simulate the bug: `flushRename` erroneously writes B's name ("Vasi")
        // to A's path because `onRename` already captured A while local `name`
        // still held B's value.
        SessionManager.setName(dirA, "Vasi")  // the wrong write

        // B must be unaffected — this is what the fix ensures at the UI layer.
        #expect(SessionManager.sessionDetail(dirB).name == "Vasi", "B must be unchanged")
        // A is now incorrectly "Vasi" on disk — this test documents the
        // observable disk-level consequence of the bug before the fix.
        #expect(SessionManager.sessionDetail(dirA).name == "Vasi", "A was overwritten by the wrong name")
    }

    @Test("sessionRow names are independent for two sessions with the same initial name")
    func sameInitialNameRemainsIndependent() throws {
        let dirA = try Self.makeSessionDir(prefix: "session-a")
        let dirB = try Self.makeSessionDir(prefix: "session-b")
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }

        // Both start with the same name, mirroring the "vasi"/"vasi" scenario in the bug report.
        SessionManager.setName(dirA, "vasi")
        SessionManager.setName(dirB, "vasi")

        // User renames A to "Or".
        SessionManager.setName(dirA, "Or")

        #expect(SessionManager.sessionRow(dirA).name == "Or", "A must show the renamed value")
        #expect(SessionManager.sessionRow(dirB).name == "vasi", "B must be unaffected by renaming A")
    }
}
