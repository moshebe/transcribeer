import Foundation
import Testing
@testable import TranscribeerApp

/// Tests for `SessionManager.gcAbandonedSessions` — the launch-time sweep that
/// cleans up session directories left behind by auto-record flicker (multiple
/// meeting-detection start attempts, none of which ever produced a merged
/// audio artifact).
struct SessionManagerGCTests {
    // MARK: - Helpers

    /// Unique temp directory for each test. `SessionManager` operates on paths
    /// with `expandingTildeInPath`, so any absolute path works.
    private static func makeSessionsDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribeer-gc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func makeSession(
        in sessionsDir: URL,
        name: String,
        files: [String: String] = [:],
        startedAt: Date? = nil,
    ) throws -> URL {
        let dir = sessionsDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (filename, contents) in files {
            let data = Data(contents.utf8)
            try data.write(to: dir.appendingPathComponent(filename))
        }
        if let startedAt {
            let meta: [String: Any] = [
                "startedAt": SessionManager.isoFormatter.string(from: startedAt),
            ]
            SessionManager.writeMeta(dir, meta)
        }
        return dir
    }

    // MARK: - isAbandoned

    @Test("Empty old directory is abandoned")
    func emptyOldDirIsAbandoned() throws {
        let sessionsDir = try Self.makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let dir = try Self.makeSession(
            in: sessionsDir,
            name: "empty",
            startedAt: Date().addingTimeInterval(-300),
        )
        #expect(SessionManager.isAbandoned(sessionDir: dir))
    }

    @Test("Directory with only leftover .caf files is abandoned")
    func cafOnlyDirIsAbandoned() throws {
        // Reproduces the Zoom-flicker bug: auto-record kicked off, wrote .caf
        // stems, then meeting-detector flickered off and the session was
        // abandoned before the pipeline merged them into audio.m4a.
        let sessionsDir = try Self.makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let dir = try Self.makeSession(
            in: sessionsDir,
            name: "caf-only",
            files: ["audio.sys.caf": "stub", "audio.mic.caf": "stub"],
            startedAt: Date().addingTimeInterval(-300),
        )
        #expect(SessionManager.isAbandoned(sessionDir: dir))
    }

    @Test("Directory with audio.m4a is kept")
    func m4aIsKept() throws {
        let sessionsDir = try Self.makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let dir = try Self.makeSession(
            in: sessionsDir,
            name: "real",
            files: ["audio.m4a": "stub"],
            startedAt: Date().addingTimeInterval(-300),
        )
        #expect(!SessionManager.isAbandoned(sessionDir: dir))
    }

    @Test("Directory with transcript.txt is kept even without audio")
    func transcriptIsKept() throws {
        let sessionsDir = try Self.makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let dir = try Self.makeSession(
            in: sessionsDir,
            name: "tx",
            files: ["transcript.txt": "hello"],
            startedAt: Date().addingTimeInterval(-300),
        )
        #expect(!SessionManager.isAbandoned(sessionDir: dir))
    }

    @Test("Directory younger than minAge is kept (may be in-flight)")
    func youngDirIsKept() throws {
        let sessionsDir = try Self.makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let dir = try Self.makeSession(
            in: sessionsDir,
            name: "fresh",
            startedAt: Date().addingTimeInterval(-5),
        )
        #expect(!SessionManager.isAbandoned(sessionDir: dir, minAge: 60))
    }

    // MARK: - gcAbandonedSessions

    @Test("Sweep removes only abandoned sessions, leaves real ones intact")
    func sweepOnlyAbandoned() throws {
        let sessionsDir = try Self.makeSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }

        let old = Date().addingTimeInterval(-300)
        _ = try Self.makeSession(in: sessionsDir, name: "abandoned-1", startedAt: old)
        _ = try Self.makeSession(
            in: sessionsDir,
            name: "abandoned-2",
            files: ["audio.sys.caf": "stub"],
            startedAt: old,
        )
        _ = try Self.makeSession(
            in: sessionsDir,
            name: "keeper",
            files: ["audio.m4a": "stub"],
            startedAt: old,
        )
        _ = try Self.makeSession(
            in: sessionsDir,
            name: "fresh",
            startedAt: Date(),
        )

        let trashed = SessionManager.gcAbandonedSessions(sessionsDir: sessionsDir.path)
        #expect(trashed.count == 2)
        #expect(trashed.contains { $0.lastPathComponent == "abandoned-1" })
        #expect(trashed.contains { $0.lastPathComponent == "abandoned-2" })

        // Keeper and the fresh (possibly-in-flight) session remain on disk.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: sessionsDir.path)
        #expect(remaining.contains("keeper"))
        #expect(remaining.contains("fresh"))
    }
}
