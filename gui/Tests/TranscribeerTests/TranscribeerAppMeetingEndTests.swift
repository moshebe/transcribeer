import Testing
@testable import TranscribeerApp

/// Unit tests for `TranscribeerApp.meetingChangeAction` — the pure decision that
/// maps a meeting state transition to a routing action. Covers the scenarios
/// requested when adding process-exit based meeting-end detection.
struct TranscribeerAppMeetingChangeActionTests {
    typealias Inputs = TranscribeerApp.MeetingChangeInputs

    private func inputs(
        inMeeting: Bool,
        isRecording: Bool = false,
        isBusy: Bool = false,
        autoRecordEnabled: Bool = true,
        hasCountdown: Bool = false,
        autoStarted: Bool = false,
        inAutoRecordCooldown: Bool = false,
    ) -> Inputs {
        Inputs(
            inMeeting: inMeeting,
            isRecording: isRecording,
            isBusy: isBusy,
            autoRecordEnabled: autoRecordEnabled,
            hasCountdown: hasCountdown,
            autoStarted: autoStarted,
            inAutoRecordCooldown: inAutoRecordCooldown,
        )
    }

    // MARK: - Meeting end (inMeeting: false)

    @Test("Meeting-end during auto-started recording selects stopRecording")
    func endDuringAutoRecordingSelectsStop() {
        let action = TranscribeerApp.meetingChangeAction(
            inputs(inMeeting: false, isRecording: true, isBusy: true, autoStarted: true),
        )
        #expect(action == .stopRecording)
    }

    @Test("Meeting-end during manually-started recording selects no action")
    func endDuringManualRecordingIsNoop() {
        let action = TranscribeerApp.meetingChangeAction(
            inputs(inMeeting: false, isRecording: true, isBusy: true, autoStarted: false),
        )
        #expect(action == .noop)
    }

    @Test("Meeting-end during countdown selects countdown cancellation")
    func endDuringCountdownSelectsCancel() {
        let action = TranscribeerApp.meetingChangeAction(
            inputs(inMeeting: false, hasCountdown: true),
        )
        #expect(action == .cancelCountdown)
    }

    @Test("Meeting-end during countdown AND auto-started recording selects cancellation and stop actions")
    func endSelectsCancelAndStop() {
        // Pathological but possible if a new detection kicked off a countdown while
        // a previous auto-recording was still in progress.
        let action = TranscribeerApp.meetingChangeAction(
            inputs(
                inMeeting: false,
                isRecording: true,
                isBusy: true,
                hasCountdown: true,
                autoStarted: true,
            ),
        )
        #expect(action == .cancelCountdownAndStopRecording)
    }

    @Test("Meeting-end while idle is a noop")
    func endWhileIdleIsNoop() {
        let action = TranscribeerApp.meetingChangeAction(inputs(inMeeting: false))
        #expect(action == .noop)
    }

    // MARK: - Meeting start (inMeeting: true) — existing behaviour sanity checks

    @Test("Meeting-start with auto-record enabled selects the auto-record action")
    func startSelectsAutoRecord() {
        let action = TranscribeerApp.meetingChangeAction(inputs(inMeeting: true))
        #expect(action == .scheduleAutoRecord)
    }

    @Test("Meeting-start with auto-record disabled selects the notification action")
    func startSelectsNotification() {
        let action = TranscribeerApp.meetingChangeAction(
            inputs(inMeeting: true, autoRecordEnabled: false),
        )
        #expect(action == .sendMeetingNotification)
    }

    @Test("Meeting-start while already recording selects no action")
    func startWhileRecordingIsNoop() {
        let action = TranscribeerApp.meetingChangeAction(
            inputs(
                inMeeting: true,
                isRecording: true,
                isBusy: true,
                autoRecordEnabled: false,
                autoStarted: true,
            ),
        )
        #expect(action == .noop)
    }

    // MARK: - Auto-record cooldown (detector flicker suppression)

    @Test("Meeting-start within the auto-record cooldown is a noop")
    func startWithinCooldownIsNoop() {
        // Classic flicker: auto-stopped seconds ago, detector bounces back to
        // `inMeeting=true` — suppress so we don't spawn a second session.
        let action = TranscribeerApp.meetingChangeAction(
            inputs(inMeeting: true, inAutoRecordCooldown: true),
        )
        #expect(action == .noop)
    }

    @Test("Cooldown selects no action for manual meeting notifications")
    func cooldownSelectsNoNotification() {
        let action = TranscribeerApp.meetingChangeAction(
            inputs(
                inMeeting: true,
                autoRecordEnabled: false,
                inAutoRecordCooldown: true,
            ),
        )
        #expect(action == .noop)
    }
}
