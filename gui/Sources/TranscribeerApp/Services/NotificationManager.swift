import TranscribeerCore
import UserNotifications

/// Wraps UNUserNotificationCenter for transcription notifications.
enum NotificationManager {
    static let meetingCategory = "MEETING_DETECTED"
    static let meetingCountdownCategory = "MEETING_AUTO_RECORD_COUNTDOWN"
    static let recordAction = "record"
    static let cancelAutoRecordAction = "cancel_auto_record"
    static let meetingIdentifier = "meeting_detected"
    static let meetingCountdownIdentifier = "meeting_auto_record_countdown"

    static func setup() {
        let center = UNUserNotificationCenter.current()

        let startAction = UNNotificationAction(
            identifier: recordAction,
            title: "⏺ Start Recording",
            options: .foreground
        )
        let dismissAction = UNNotificationAction(
            identifier: "dismiss",
            title: "Dismiss",
            options: []
        )
        let cancelAction = UNNotificationAction(
            identifier: cancelAutoRecordAction,
            title: "⏹ Cancel",
            options: [.destructive, .foreground]
        )

        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: meetingCategory,
                actions: [startAction, dismissAction],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: meetingCountdownCategory,
                actions: [cancelAction],
                intentIdentifiers: [],
                options: []
            ),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post a one-shot notification with `sound = .default` and a fresh UUID
    /// identifier. Used for the idempotent "transcription complete"-style alerts.
    private static func postTransient(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }

    static func notifyDone(sessionName: String) {
        postTransient(title: "Transcription complete", body: "Session saved: \(sessionName)")
    }

    static func notifyError(_ message: String) {
        postTransient(title: "Transcribeer error", body: message)
    }

    static func notifyScheduledBatch(count: Int) {
        let body = count == 1
            ? "Processed 1 recording from yesterday."
            : "Processed \(count) recordings from yesterday."
        postTransient(title: "Overnight transcriptions complete", body: body)
    }

    /// "Meeting in progress" prompt — offered while idle, with a Start Recording action.
    static func sendMeetingNotification(appName: String?) {
        let content = UNMutableNotificationContent()
        content.title = appName.map { "\($0) meeting in progress" } ?? "Meeting in progress"
        content.body = "No recording active — want to record this meeting?"
        content.categoryIdentifier = meetingCategory

        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: meetingIdentifier,
            content: content,
            trigger: nil
        ))
    }

    static func notifyMeetingAutoRecordStarted(appName: String?, title: String?) {
        let heading = appName.map { "Recording \($0) meeting" } ?? "Recording meeting"
        let body = if let title, !title.isEmpty { title } else { "Auto-record started." }
        postTransient(title: heading, body: body)
    }

    static func cancelMeetingNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [meetingIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [meetingIdentifier])
    }

    /// Post or update the "auto-recording in Ns…" countdown banner.
    /// Reuses the same identifier so subsequent calls replace the existing
    /// notification in place instead of stacking.
    static func showMeetingCountdown(secondsRemaining: Int, appName: String?, title: String?) {
        let content = UNMutableNotificationContent()
        let appSuffix = appName.map { " \($0)" } ?? ""
        content.title = "Auto-recording\(appSuffix) in \(secondsRemaining)s"
        content.body = if let title, !title.isEmpty {
            "\(title) — tap Cancel to skip."
        } else {
            "Tap Cancel to skip auto-record."
        }
        content.categoryIdentifier = meetingCountdownCategory
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: meetingCountdownIdentifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func cancelMeetingCountdown() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [meetingCountdownIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [meetingCountdownIdentifier])
    }
}
