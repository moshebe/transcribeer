import TranscribeerCore
import UserNotifications

/// Wraps UNUserNotificationCenter for transcription notifications.
enum NotificationManager {
    static let zoomCategory = "ZOOM_MEETING"
    static let recordAction = "record"

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
        let category = UNNotificationCategory(
            identifier: zoomCategory,
            actions: [recordAction, dismissAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
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

    static func cancelZoomNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["zoom_meeting"])
        center.removeDeliveredNotifications(withIdentifiers: ["zoom_meeting"])
    }
}
