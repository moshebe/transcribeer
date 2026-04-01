import UserNotifications

enum NotificationManager {
    static func requestPermission() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "notificationsRequested") else { return }
        defaults.set(true, forKey: "notificationsRequested")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    static func notifyDone(sessionPath: String) {
        let name = URL(fileURLWithPath: sessionPath).lastPathComponent
        notify(title: "Transcription complete", body: "Session saved to \(name)")
    }

    static func notifyError(_ message: String) {
        notify(title: "Transcribee error", body: message)
    }
}
