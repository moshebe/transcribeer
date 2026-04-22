import UserNotifications

/// Wraps UNUserNotificationCenter for transcription notifications.
enum NotificationManager {
    static let zoomCategory = "ZOOM_MEETING"
    static let zoomCountdownCategory = "ZOOM_AUTO_RECORD_COUNTDOWN"
    static let recordAction = "record"
    static let cancelAutoRecordAction = "cancel_auto_record"
    static let zoomCountdownIdentifier = "zoom_auto_record_countdown"

    static func setup() {
        let center = UNUserNotificationCenter.current()

        let recordAction = UNNotificationAction(
            identifier: Self.recordAction,
            title: "⏺ Start Recording",
            options: .foreground
        )
        let dismissAction = UNNotificationAction(
            identifier: "dismiss",
            title: "Dismiss",
            options: []
        )
        let zoomCategory = UNNotificationCategory(
            identifier: Self.zoomCategory,
            actions: [recordAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )

        let cancelAction = UNNotificationAction(
            identifier: Self.cancelAutoRecordAction,
            title: "⏹ Cancel",
            options: [.destructive, .foreground]
        )
        let countdownCategory = UNNotificationCategory(
            identifier: Self.zoomCountdownCategory,
            actions: [cancelAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([zoomCategory, countdownCategory])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifyDone(sessionName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transcription complete"
        content.body = "Session saved: \(sessionName)"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func notifyError(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transcribeer error"
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func sendZoomNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Zoom meeting in progress"
        content.body = "No recording active — want to record this meeting?"
        content.categoryIdentifier = zoomCategory

        let request = UNNotificationRequest(
            identifier: "zoom_meeting",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func notifyZoomAutoRecordStarted(title: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Recording Zoom meeting"
        if let title, !title.isEmpty {
            content.body = title
        } else {
            content.body = "Auto-record started."
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func cancelZoomNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["zoom_meeting"])
        center.removeDeliveredNotifications(withIdentifiers: ["zoom_meeting"])
    }

    /// Post or update the "auto-recording in Ns…" countdown banner.
    /// Reuses the same identifier so subsequent calls replace the existing
    /// notification in place instead of stacking.
    static func showZoomCountdown(secondsRemaining: Int, title: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Auto-recording Zoom in \(secondsRemaining)s"
        if let title, !title.isEmpty {
            content.body = "\(title) — tap Cancel to skip."
        } else {
            content.body = "Tap Cancel to skip auto-record."
        }
        content.categoryIdentifier = zoomCountdownCategory
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: zoomCountdownIdentifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func cancelZoomCountdown() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [zoomCountdownIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [zoomCountdownIdentifier])
    }
}
