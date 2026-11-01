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

        _ = try Self.makeSession(
            in: sessionsDir,
            name: "transcript-only",
            files: ["transcript.txt": "hello"],
            startedAt: old,
        )

        let trashed = SessionManager.gcAbandonedSessions(sessionsDir: sessionsDir.path)
        #expect(trashed.count == 2)
        #expect(trashed.contains { $0.lastPathComponent == "abandoned-1" })
        #expect(trashed.contains { $0.lastPathComponent == "abandoned-2" })

        // Keeper and the fresh (possibly-in-flight) session remain on disk.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: sessionsDir.path)
        #expect(remaining.contains("keeper"))
        #expect(remaining.contains("fresh"))
        #expect(remaining.contains("transcript-only"))
        #expect(remaining.contains("abandoned-1") == false)
        #expect(remaining.contains("abandoned-2") == false)
    }
}
