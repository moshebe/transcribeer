import Foundation
import os.log

private let logger = Logger(subsystem: "com.transcribeer", category: "scheduler")

/// Daily background job that transcribes and summarizes all sessions started
/// the previous calendar day. Fires at the configured local hour (default 3 AM).
///
/// The service owns a single long-lived `Task` that sleeps until the next fire
/// time, runs the batch, then re-arms. Reading the current config and runner
/// state happens through closures supplied at `start(...)` so the scheduler
/// always sees fresh values without holding stale references.
@Observable
@MainActor
final class ScheduledTranscriptionService {
    /// Last calendar day (`Calendar.startOfDay`) that the scheduler completed
    /// a batch for. Surfaced for diagnostics and to drive a "ran at <time>"
    /// label in Settings later.
    private(set) var lastRunDate: Date?

    /// Number of sessions processed in the last batch (transcribed +
    /// summarized count). Reset to zero when a new batch starts.
    private(set) var lastRunSessionCount = 0

    private var task: Task<Void, Never>?
    private weak var runner: PipelineRunner?
    private var configProvider: () -> AppConfig = { AppConfig() }

    func start(runner: PipelineRunner, configProvider: @escaping () -> AppConfig) {
        self.runner = runner
        self.configProvider = configProvider
        reschedule()
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Cancel the in-flight wait + restart with the latest config. Call after
    /// the user toggles the schedule or changes the hour so the change takes
    /// effect immediately rather than at the next fire.
    func reschedule() {
        task?.cancel()
        task = Task { [weak self] in
            await self?.run()
        }
    }

    // MARK: - Worker

    private func run() async {
        while !Task.isCancelled {
            let cfg = configProvider()
            guard cfg.scheduledTranscriptionEnabled else {
                logger.info("scheduler disabled — exiting loop")
                return
            }
            let now = Date()
            let fireAt = Self.nextFireDate(after: now, hour: cfg.scheduledTranscriptionHour)
            let interval = fireAt.timeIntervalSince(now)
            logger.info("next run at \(fireAt, privacy: .public) (in \(Int(interval), privacy: .public)s)")
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }
            await runBatch(referenceDate: Date(), config: configProvider())
        }
    }

    private func runBatch(referenceDate: Date, config: AppConfig) async {
        guard let runner else { return }
        if runner.state.isBusy {
            logger.info("scheduler skipped — runner busy at fire time")
            lastRunDate = Calendar.current.startOfDay(for: referenceDate)
            lastRunSessionCount = 0
            return
        }

        let all = SessionManager.listSessions(sessionsDir: config.expandedSessionsDir)
        let pending = Self.sessionsToProcess(sessions: all, referenceDate: referenceDate)
        logger.info("batch start: \(pending.count, privacy: .public) session(s) to process")

        var processed = 0
        for session in pending {
            if Task.isCancelled { break }
            await processSession(session, runner: runner, config: config)
            processed += 1
        }

        lastRunDate = Calendar.current.startOfDay(for: referenceDate)
        lastRunSessionCount = processed
        logger.info("batch done: processed \(processed, privacy: .public) session(s)")
        if processed > 0 {
            NotificationManager.notifyScheduledBatch(count: processed)
        }
    }

    private func processSession(_ session: Session, runner: PipelineRunner, config: AppConfig) async {
        if !session.hasTranscript, session.hasAudio {
            let result = await runner.transcribeSession(session.path, config: config)
            if !result.ok {
                logger.error("scheduled transcribe failed for \(session.path.path, privacy: .public): \(result.error, privacy: .public)")
                return
            }
        }
        let txExists = FileManager.default.fileExists(
            atPath: session.path.appendingPathComponent("transcript.txt").path,
        )
        let smExists = FileManager.default.fileExists(
            atPath: session.path.appendingPathComponent("summary.md").path,
        )
        if txExists, !smExists {
            let result = await runner.summarizeSession(session.path, config: config, profile: nil)
            if !result.ok {
                logger.error("scheduled summarize failed for \(session.path.path, privacy: .public): \(result.error, privacy: .public)")
            }
        }
    }

    // MARK: - Pure helpers (testable)

    /// Compute the next `hour:00` boundary strictly after `now` in the given
    /// calendar's local time. Today's boundary if it hasn't passed yet,
    /// otherwise tomorrow's. Out-of-range hours are clamped to `[0, 23]`.
    nonisolated static func nextFireDate(
        after now: Date,
        hour: Int,
        calendar: Calendar = .current,
    ) -> Date {
        let clamped = max(0, min(23, hour))
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = clamped
        components.minute = 0
        components.second = 0
        let candidate = calendar.date(from: components) ?? now
        if candidate > now {
            return candidate
        }
        return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }

    /// Sessions worth processing in the batch fired at `referenceDate`.
    ///
    /// "Previous day" means the calendar day before the day of `referenceDate`
    /// in the supplied calendar's local time. A session is included when:
    /// 1. it started during the previous day, and
    /// 2. it has audio on disk but is missing a transcript or summary.
    nonisolated static func sessionsToProcess(
        sessions: [Session],
        referenceDate: Date,
        calendar: Calendar = .current,
    ) -> [Session] {
        let todayStart = calendar.startOfDay(for: referenceDate)
        guard let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart)
        else { return [] }
        return sessions.filter { session in
            guard session.date >= yesterdayStart, session.date < todayStart else { return false }
            if !session.hasAudio { return false }
            return !session.hasTranscript || !session.hasSummary
        }
    }
}
