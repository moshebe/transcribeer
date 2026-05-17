import Foundation
import os

/// Passive polling observer for Zoom's participants side panel.
///
/// Does **not** open the panel — reports whatever state Zoom is already in. The
/// consumer should only expect a snapshot while the user has the panel visible.
///
/// Logging strategy (category `zoom-participants`):
/// - **`.info`** on every state transition (panel open/close, participant
///   count or name set changes).
/// - **`.debug`** on unchanged polls, gated by `pollDebugEvery` so Console
///   stays readable during long meetings.
@Observable
@MainActor
final class ZoomParticipantsWatcher {
    /// Most recently observed participants. Retained while the panel is open;
    /// cleared when Zoom quits so stale data doesn't bleed across meetings.
    private(set) var snapshot: ZoomParticipantsReader.Snapshot?
    /// Last AX lookup outcome. Useful for diagnostic UI ("panel closed").
    private(set) var lastState: ZoomParticipantsReader.LookupState?

    private let pollInterval: Duration
    /// Emit a debug log every Nth identical poll so we can confirm the watcher
    /// is alive without spamming one line per second.
    private let pollDebugEvery: Int
    private var pollTask: Task<Void, Never>?
    private var stateStreak = 0
    private let logger = Logger(subsystem: "com.transcribeer", category: "zoom-participants")

    init(pollInterval: Duration = .seconds(2), pollDebugEvery: Int = 30) {
        self.pollInterval = pollInterval
        self.pollDebugEvery = max(pollDebugEvery, 1)
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        logger.info("participants watcher started (poll \(self.pollInterval, privacy: .public))")
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func stop() {
        guard pollTask != nil else { return }
        pollTask?.cancel()
        pollTask = nil
        lastState = nil
        snapshot = nil
        stateStreak = 0
        logger.info("participants watcher stopped")
    }

    // MARK: - Poll loop

    private func pollLoop() async {
        // First tick is immediate so the UI reacts without waiting a full interval.
        pollOnce()
        while !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            guard !Task.isCancelled else { break }
            pollOnce()
        }
    }

    private func pollOnce() {
        let result = ZoomParticipantsReader.lookup()
        applyResult(result)
    }

    // MARK: - State application

    private func applyResult(_ result: ZoomParticipantsReader.LookupResult) {
        let transitioned = lastState != result.state
        if transitioned {
            logTransition(from: lastState, to: result.state, snapshot: result.snapshot)
            lastState = result.state
            stateStreak = 1
        } else {
            stateStreak += 1
            if stateStreak.isMultiple(of: pollDebugEvery) {
                logger.debug(
                    "state unchanged (\(result.state.shortDescription, privacy: .public)) × \(self.stateStreak, privacy: .public) polls",
                )
            }
        }

        switch result.state {
        case .found:
            let old = snapshot
            snapshot = result.snapshot
            if let new = result.snapshot, let prev = old {
                logContentChange(previous: prev, current: new)
            }

        case .zoomNotRunning:
            snapshot = nil

        case .noMeetingWindow, .panelClosed, .axError:
            // Keep last snapshot so consumers (e.g. diarization seeding) retain
            // the most recent participant list across transient closes.
            break
        }
    }

    private func logTransition(
        from previous: ZoomParticipantsReader.LookupState?,
        to current: ZoomParticipantsReader.LookupState,
        snapshot: ZoomParticipantsReader.Snapshot?,
    ) {
        let prev = previous?.shortDescription ?? "nil"
        logger.info("state \(prev, privacy: .public) → \(current.shortDescription, privacy: .public)")
        if case .found = current, let snapshot {
            logSnapshotContents(snapshot)
        }
    }

    private func logContentChange(
        previous: ZoomParticipantsReader.Snapshot,
        current: ZoomParticipantsReader.Snapshot,
    ) {
        let previousNames = Set(previous.participants.map(\.displayName))
        let currentNames = Set(current.participants.map(\.displayName))
        if previousNames == currentNames,
           speakingSignature(previous.participants) == speakingSignature(current.participants) {
            return
        }
        let joined = currentNames.subtracting(previousNames).sorted()
        let left = previousNames.subtracting(currentNames).sorted()
        let speaking = current.participants.filter(\.isSpeaking).map(\.displayName).sorted()
        let joinedStr = joined.isEmpty ? "-" : joined.joined(separator: ",")
        let leftStr = left.isEmpty ? "-" : left.joined(separator: ",")
        let speakingStr = speaking.isEmpty ? "-" : speaking.joined(separator: ",")
        logger.info(
            "participants changed: +[\(joinedStr, privacy: .public)] -[\(leftStr, privacy: .public)] speaking=[\(speakingStr, privacy: .public)]",
        )
    }

    private func logSnapshotContents(_ snapshot: ZoomParticipantsReader.Snapshot) {
        let names = snapshot.participants.map { participant in
            var tags: [String] = []
            if participant.isMe { tags.append("me") }
            if participant.isHost { tags.append("host") }
            if participant.isCoHost { tags.append("co-host") }
            if participant.isGuest { tags.append("guest") }
            if participant.isSpeaking { tags.append("speaking") }
            let suffix = tags.isEmpty ? "" : " [\(tags.joined(separator: ","))]"
            return "\(participant.displayName)\(suffix)"
        }
        logger.info(
            "panel open, \(snapshot.count, privacy: .public) participant(s): \(names.joined(separator: "; "), privacy: .public)",
        )
    }

    private func speakingSignature(_ participants: [ZoomParticipantsReader.Participant]) -> [String] {
        participants.filter(\.isSpeaking).map(\.displayName).sorted()
    }
}
