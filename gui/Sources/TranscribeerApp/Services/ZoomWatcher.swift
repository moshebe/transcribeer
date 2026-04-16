import AppKit
import TranscribeerCore

/// Watches for Zoom meeting processes via NSWorkspace polling.
@Observable
@MainActor
final class ZoomWatcher {
    /// True when us.zoom.caphost is running (active Zoom meeting).
    var inMeeting = false

    private static let meetingBundle = "us.zoom.caphost"
    private static let titleBundles: Set<String> = ["us.zoom.xos", "us.zoom.caphost"]
    private static let genericTitles: Set<String> = ["zoom", "zoom meeting", "zoom workplace"]

    private var pollTimer: Timer?

    func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.check()
            }
        }
        check()
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func check() {
        let nowInMeeting = hasActiveMeetingWindow()
        if nowInMeeting != inMeeting {
            inMeeting = nowInMeeting
        }
    }

    /// Check for a Zoom meeting window via Accessibility APIs.
    /// A running process alone is not enough — we need an actual meeting window.
    private func hasActiveMeetingWindow() -> Bool {
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  Self.titleBundles.contains(bundleID) else { continue }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }

            for window in windows {
                var titleRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                      let title = titleRef as? String,
                      !title.isEmpty else { continue }

                let lower = title.lowercased()
                // Skip generic/home screen titles — only match actual meeting windows
                if Self.genericTitles.contains(lower) { continue }
                return true
            }
        }
        return false
    }

    /// Attempt to read the Zoom meeting title via Accessibility APIs.
    func meetingTitle() -> String? {
        let workspace = NSWorkspace.shared
        for app in workspace.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  Self.titleBundles.contains(bundleID) else { continue }

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else { continue }

            for window in windows {
                var titleRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
                      let rawTitle = titleRef as? String else { continue }
                if let cleaned = Self.cleanZoomTitle(rawTitle) {
                    return cleaned
                }
            }
        }
        return nil
    }

    private static func cleanZoomTitle(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return nil }

        for suffix in [" - Zoom", " | Zoom", " — Zoom", " – Zoom"] {
            if title.hasSuffix(suffix) {
                title = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
        }

        if title.isEmpty || genericTitles.contains(title.lowercased()) {
            return nil
        }
        return title
    }
}
