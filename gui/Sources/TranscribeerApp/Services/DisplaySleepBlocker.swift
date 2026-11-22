import Foundation
import os.log

private let logger = Logger(subsystem: "com.transcribeer", category: "display-sleep")

/// Holds a `ProcessInfo` activity that prevents idle display (and system) sleep.
/// `acquire()` and `release()` are idempotent.
@MainActor
final class DisplaySleepBlocker {
    private var activity: NSObjectProtocol?

    var isActive: Bool { activity != nil }

    func acquire() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated],
            reason: "Recording in progress",
        )
        logger.info("display sleep blocked")
    }

    func release() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
        logger.info("display sleep released")
    }
}
