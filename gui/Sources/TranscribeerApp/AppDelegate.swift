import AppKit
import os.log
import UserNotifications

private let logger = Logger(subsystem: "com.transcribeer", category: "delegate")

/// Handles app lifecycle events and notification delegation.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var onRecord: (() -> Void)?
    var onCancelAutoRecord: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("applicationDidFinishLaunching")
        configureAppIcon()
        ShellEnvironment.load()
        NotificationManager.setup()
        UNUserNotificationCenter.current().delegate = self
        logger.info("startup complete")
    }

    @MainActor
    private func configureAppIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            logger.error("AppIcon.icns missing from bundle resources")
            return
        }
        guard let icon = NSImage(contentsOf: iconURL) else {
            logger.error("Failed to load AppIcon.icns at \(iconURL.path)")
            return
        }
        NSApp.applicationIconImage = icon
        DockTileBadger.register(baseIcon: icon)
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let id = response.actionIdentifier
        let notificationID = response.notification.request.identifier

        if id == NotificationManager.cancelAutoRecordAction {
            onCancelAutoRecord?()
            return
        }

        let isRecordIntent = id == NotificationManager.recordAction
            || id == UNNotificationDefaultActionIdentifier
        // Tapping the body of the countdown notification shouldn't trigger a
        // generic "record" action — recording is already queued.
        guard isRecordIntent,
              notificationID != NotificationManager.meetingCountdownIdentifier
        else { return }
        onRecord?()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
