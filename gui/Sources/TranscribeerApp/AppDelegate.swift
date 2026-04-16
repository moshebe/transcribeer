import AppKit
import os.log
import UserNotifications
import TranscribeerCore

private let logger = Logger(subsystem: "com.transcribeer", category: "delegate")

/// Handles app lifecycle events and notification delegation.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var onRecord: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("applicationDidFinishLaunching")
        ShellEnvironment.load()
        NotificationManager.setup()
        UNUserNotificationCenter.current().delegate = self
        logger.info("startup complete")
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.actionIdentifier
        if id == NotificationManager.recordAction
            || id == UNNotificationDefaultActionIdentifier {
            onRecord?()
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
