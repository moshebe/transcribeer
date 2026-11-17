import Foundation

extension PipelineRunner {
    /// Match against the events in progress as soon as recording starts, so
    /// the session has its event name while it records. The stop-time match in
    /// `runRecording` refines it with the full window.
    func startCalendarMatch(for session: URL, startedAt: Date, config: AppConfig) {
        guard config.calendarEnricherEnabled else { return }
        calendarStartTask = Task {
            let line = await CalendarEnricher.enrich(
                session: session,
                start: startedAt,
                end: nil,
                stage: .start,
                config: config,
            )
            if let line { SessionLogger(logPath: session.appendingPathComponent("run.log")).log(line) }
        }
    }

    /// Stamp the wall-clock end of the capture (the sidebar shows a
    /// "10:30 - 11:15" range), then match the full window to a calendar event.
    /// Runs before transcription, so later stages can read the event.
    func stampRecordingEnd(
        _ session: URL,
        startedAt: Date,
        config: AppConfig,
        log: (String) -> Void,
    ) async {
        let endedAt = Date()
        SessionManager.setRecordingTimes(session, startedAt: startedAt, endedAt: endedAt)
        // The stop match is authoritative: the start match must not write after it.
        calendarStartTask?.cancel()
        await calendarStartTask?.value
        calendarStartTask = nil
        let line = await CalendarEnricher.enrich(
            session: session,
            start: startedAt,
            end: endedAt,
            stage: .stop,
            config: config,
        )
        if let line { log(line) }
    }
}
