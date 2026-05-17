import Foundation
import os

/// Bridges `ZoomParticipantsWatcher` snapshots into a recording session's
/// `meta.json`. Active only while a recording is in progress.
///
/// - Subscribes to the shared watcher via `withObservationTracking` rather
///   than running its own poll loop, so there's exactly one AX walk per tick.
/// - Every observed snapshot is merged (not overwritten) through
///   `SessionManager.appendParticipants` so the saved list grows across the
///   meeting even when people briefly leave or the user closes the panel.
/// - Only the set of participants and their role flags persist; transient
///   state (speaking, mic, video) is intentionally dropped.
/// - Skips collection entirely while the observed count exceeds
///   `maxParticipants` so large webinars / classrooms don't flood meta.json.
@MainActor
final class SessionParticipantsRecorder {
    private let session: URL
    private let watcher: ZoomParticipantsWatcher
    /// Upper bound on participants we'll persist for this session. Values
    /// `<= 0` disable collection entirely.
    private let maxParticipants: Int
    private let now: () -> Date
    private let logger = Logger(subsystem: "com.transcribeer", category: "session-participants")
    private var stopped = false
    /// Last applied snapshot's read time, used to dedupe `onChange` re-arm
    /// re-entries that fire with the same snapshot reference.
    private var lastAppliedAt: Date?
    /// Whether the previous observation was over the threshold. Tracked so
    /// we log a single line per transition into / out of the "too big" state
    /// instead of one per poll.
    private var previouslyOverThreshold = false

    init(
        session: URL,
        watcher: ZoomParticipantsWatcher,
        maxParticipants: Int,
        now: @escaping () -> Date = Date.init,
    ) {
        self.session = session
        self.watcher = watcher
        self.maxParticipants = maxParticipants
        self.now = now
    }

    /// Pure threshold check. Extracted so tests don't need a live watcher.
    /// `maxParticipants <= 0` disables collection; otherwise collect while
    /// `observedCount <= maxParticipants`.
    nonisolated static func shouldTrack(observedCount: Int, maxParticipants: Int) -> Bool {
        maxParticipants > 0 && observedCount <= maxParticipants
    }

    /// Begin observing. Apply the current snapshot immediately so a recording
    /// that starts with the panel already open captures the initial state.
    func start() {
        guard !stopped else { return }
        logger.info(
            "started for session \(self.session.lastPathComponent, privacy: .public) cap=\(self.maxParticipants, privacy: .public)",
        )
        apply(watcher.snapshot)
        arm()
    }

    /// Stop observing. Idempotent. After `stop()` no further writes occur
    /// even if the watcher continues publishing.
    func stop() {
        guard !stopped else { return }
        stopped = true
        logger.info("stopped for session \(self.session.lastPathComponent, privacy: .public)")
    }

    // MARK: - Observation

    private func arm() {
        guard !stopped else { return }
        withObservationTracking {
            _ = watcher.snapshot
        } onChange: { [weak self] in
            // onChange fires outside the MainActor; hop back before touching state.
            Task { @MainActor [weak self] in
                guard let self, !stopped else { return }
                apply(watcher.snapshot)
                arm()
            }
        }
    }

    private func apply(_ snapshot: ZoomParticipantsReader.Snapshot?) {
        guard let snapshot, !snapshot.participants.isEmpty else { return }
        if let lastAppliedAt, lastAppliedAt == snapshot.readAt { return }
        lastAppliedAt = snapshot.readAt

        guard Self.shouldTrack(observedCount: snapshot.count, maxParticipants: maxParticipants) else {
            if !previouslyOverThreshold {
                previouslyOverThreshold = true
                logger.info(
                    "skipping collection: \(snapshot.count, privacy: .public) participants > cap \(self.maxParticipants, privacy: .public)",
                )
            }
            return
        }
        if previouslyOverThreshold {
            previouslyOverThreshold = false
            logger.info(
                "resuming collection: \(snapshot.count, privacy: .public) participants within cap \(self.maxParticipants, privacy: .public)",
            )
        }

        let observedAt = now()
        let observations = snapshot.participants
            .filter { !$0.displayName.isEmpty }
            .map { participant in
                SessionParticipant(
                    name: participant.displayName,
                    observedAt: observedAt,
                    isMe: participant.isMe,
                    isHost: participant.isHost,
                    isCoHost: participant.isCoHost,
                    isGuest: participant.isGuest,
                )
            }
        guard !observations.isEmpty else { return }

        let merged = SessionManager.appendParticipants(session, observed: observations)
        logger.info(
            "merged \(observations.count, privacy: .public) observation(s) -> \(merged.count, privacy: .public) total in session",
        )
    }
}
