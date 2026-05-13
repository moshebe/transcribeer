import Foundation
import Testing
@testable import TranscribeerApp

@Suite("SessionParticipants")
struct SessionParticipantsTests {
    // MARK: - Merge logic

    @Test
    func mergePreservesExistingWhenNoObservations() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let existing = [participant("Alice", at: t0, isHost: true)]
        let merged = SessionManager.mergeParticipants(existing: existing, observed: [])
        #expect(merged == existing)
    }

    @Test
    func mergeAppendsNewObservations() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = t0.addingTimeInterval(60)
        let existing = [participant("Alice", at: t0, isHost: true)]
        let observed = [participant("Bob", at: t1, isGuest: true)]
        let merged = SessionManager.mergeParticipants(existing: existing, observed: observed)
        #expect(merged.map(\.name) == ["Alice", "Bob"])
        #expect(merged[1].isGuest)
    }

    @Test
    func mergeUpdatesLastSeenForExistingParticipants() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = t0.addingTimeInterval(60)
        let existing = [participant("Alice", at: t0)]
        let observed = [participant("Alice", at: t1, isCoHost: true)]
        let merged = SessionManager.mergeParticipants(existing: existing, observed: observed)
        #expect(merged.count == 1)
        let updated = merged[0]
        #expect(updated.name == "Alice")
        #expect(updated.firstSeenAt == t0, "firstSeenAt must stay at initial observation")
        #expect(updated.lastSeenAt == t1, "lastSeenAt bumps forward")
        #expect(updated.isCoHost, "role flags OR-accumulate")
    }

    @Test
    func mergeDoesNotDowngradeRoleFlags() {
        // Someone was observed as host at t0; at t1 Zoom transferred the role
        // (no longer host). History should still remember they were host.
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = t0.addingTimeInterval(120)
        let existing = [participant("Alice", at: t0, isHost: true)]
        let observed = [participant("Alice", at: t1, isHost: false)]
        let merged = SessionManager.mergeParticipants(existing: existing, observed: observed)
        #expect(merged[0].isHost)
    }

    @Test
    func mergePreservesExistingOrderBeforeAppending() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = t0.addingTimeInterval(60)
        let existing = [
            participant("Alice", at: t0),
            participant("Bob", at: t0),
        ]
        let observed = [
            participant("Bob", at: t1),         // already present
            participant("Charlie", at: t1),     // new
            participant("Dana", at: t1),        // new
        ]
        let merged = SessionManager.mergeParticipants(existing: existing, observed: observed)
        #expect(merged.map(\.name) == ["Alice", "Bob", "Charlie", "Dana"])
    }

    @Test
    func mergeDedupesRepeatedObservationsOfSameName() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = t0.addingTimeInterval(60)
        let observed = [
            participant("Alice", at: t0),
            participant("Alice", at: t1, isHost: true),
        ]
        let merged = SessionManager.mergeParticipants(existing: [], observed: observed)
        #expect(merged.map(\.name) == ["Alice"])
        #expect(merged[0].firstSeenAt == t0)
        #expect(merged[0].lastSeenAt == t1)
        #expect(merged[0].isHost)
    }

    // MARK: - Disk round-trip

    @Test
    func appendParticipantsWritesToMeta() throws {
        let dir = try makeTempSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let t0 = Date(timeIntervalSince1970: 1_000)
        let written = SessionManager.appendParticipants(
            dir,
            observed: [participant("Alice", at: t0, isMe: true, isHost: true)],
        )
        #expect(written.count == 1)

        let readBack = SessionManager.readParticipants(dir)
        #expect(readBack == written)
        #expect(readBack[0].isHost)
        #expect(readBack[0].isMe)
    }

    // MARK: - Recorder threshold

    // Pure predicate semantics. The "observed count is zero" case is filtered
    // upstream in `apply(_:)` before `shouldTrack` is consulted, so the
    // predicate itself only judges "is this count within the cap".
    @Test(arguments: [
        // observedCount, maxParticipants, expected
        (0, 10, true),    // 0 <= 10 — cap check passes; empty list filtered by caller
        (1, 10, true),
        (10, 10, true),   // equal to cap → still track
        (11, 10, false),  // over cap → skip
        (5, 0, false),    // cap of 0 disables
        (5, -1, false),   // negative cap disables
    ])
    func shouldTrackRespectsThreshold(
        observedCount: Int,
        maxParticipants: Int,
        expected: Bool,
    ) {
        let result = SessionParticipantsRecorder.shouldTrack(
            observedCount: observedCount,
            maxParticipants: maxParticipants,
        )
        #expect(result == expected)
    }

    @Test
    func appendParticipantsIsNoopWhenUnchanged() throws {
        let dir = try makeTempSession()
        defer { try? FileManager.default.removeItem(at: dir) }

        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = SessionManager.appendParticipants(dir, observed: [participant("Alice", at: t0)])
        let firstMtime = try metaMtime(of: dir)

        // Idempotent re-write with identical data should not bump the file mtime.
        Thread.sleep(forTimeInterval: 1.1)
        _ = SessionManager.appendParticipants(dir, observed: [participant("Alice", at: t0)])
        let secondMtime = try metaMtime(of: dir)
        #expect(secondMtime == firstMtime, "unchanged merge must not touch disk")
    }

    // MARK: - Helpers

    private func participant(
        _ name: String,
        at date: Date,
        isMe: Bool = false,
        isHost: Bool = false,
        isCoHost: Bool = false,
        isGuest: Bool = false,
    ) -> SessionParticipant {
        SessionParticipant(
            name: name,
            observedAt: date,
            isMe: isMe,
            isHost: isHost,
            isCoHost: isCoHost,
            isGuest: isGuest,
        )
    }

    private func makeTempSession() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribeer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func metaMtime(of dir: URL) throws -> Date {
        let url = dir.appendingPathComponent("meta.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let date = attrs[.modificationDate] as? Date else {
            throw NSError(domain: "test", code: -1)
        }
        return date
    }
}
