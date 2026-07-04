import AppKit
import os.log
import UserNotifications

private let logger = Logger(subsystem: "com.transcribeer", category: "delegate")
private let hotkeyLogger = Logger(subsystem: "com.transcribeer", category: "hotkey")

/// App-wide build metadata.
enum AppBuild {
    /// `true` when compiled with `-DDEV_BUILD` (i.e. via `make dev` / `make gui-build`).
    /// Compile-time constant — dead code is stripped in release builds that
    /// omit the flag, so there is zero runtime overhead.
    static let isDevBuild: Bool = {
        #if DEV_BUILD
        return true
        #else
        return false
        #endif
    }()
}

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

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkeyManager.shared.unregisterAll()
    }

    // MARK: - Global hotkey

    /// Register (or re-register) the "open app" hotkey from the given config.
    /// Safe to call multiple times — re-registers on each config change.
    @MainActor
    func applyHotkey(from config: AppConfig) {
        // Always unregister the previous binding first (id 1 = open-app).
        GlobalHotkeyManager.shared.unregister(id: 1)

        let hotkeyString = config.openAppHotkey
        guard !hotkeyString.isEmpty else {
            hotkeyLogger.info("open-app hotkey disabled (empty config)")
            return
        }
        guard let descriptor = HotkeyDescriptor.parse(hotkeyString) else {
            hotkeyLogger.error("could not parse open_app_hotkey: \(hotkeyString, privacy: .public)")
            return
        }

        do {
            try GlobalHotkeyManager.shared.register(
                id: 1,
                keyCode: descriptor.keyCode,
                modifiers: descriptor.modifiers
            ) {
                hotkeyLogger.info("open-app hotkey fired — activating")
                NSApp.activate(ignoringOtherApps: true)
            }
        } catch {
            hotkeyLogger.error("hotkey registration error: \(error.localizedDescription, privacy: .public)")
        }
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
