import Foundation
import Testing
@testable import TranscribeerApp

/// Covers the round-trip of recording-window timestamps through meta.json
/// and into the `Session` value used by the sidebar.
struct SessionManagerRecordingTimesTests {
    @Test("setRecordingTimes persists both bounds and sessionRow reads them back")
    func roundTripsBothBounds() throws {
        let dir = try makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Drop fractional seconds so the ISO-8601 round-trip compares cleanly
        // (the on-disk format includes millisecond precision, which is fine,
        // but keeping the fixtures at whole seconds avoids fp jitter).
        let started = Date(timeIntervalSince1970: 1_750_000_000)
        let ended = started.addingTimeInterval(60 * 45)

        SessionManager.setRecordingTimes(dir, startedAt: started, endedAt: ended)
        let session = SessionManager.sessionRow(dir)

        #expect(session.startedAt == started)
        #expect(session.endedAt == ended)
    }

    @Test("Passing nil removes the field without touching unrelated meta")
    func clearingEndedAtPreservesName() throws {
        let dir = try makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        SessionManager.setName(dir, "Budget review")
        let started = Date(timeIntervalSince1970: 1_750_000_000)
        SessionManager.setRecordingTimes(
            dir,
            startedAt: started,
            endedAt: started.addingTimeInterval(30),
        )
        // Simulate "still recording" by clearing just the end time.
        SessionManager.setRecordingTimes(dir, startedAt: started, endedAt: nil)

        let session = SessionManager.sessionRow(dir)
        #expect(session.name == "Budget review")
        #expect(session.startedAt == started)
        #expect(session.endedAt == nil)
    }

    @Test("sessionRow tolerates meta.json without any recording-window fields")
    func missingFieldsFallBackToNil() throws {
        let dir = try makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let session = SessionManager.sessionRow(dir)
        #expect(session.startedAt == nil)
        #expect(session.endedAt == nil)
    }

    // MARK: - Helpers

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
