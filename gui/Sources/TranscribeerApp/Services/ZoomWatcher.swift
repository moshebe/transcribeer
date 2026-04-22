import AppKit
import os

/// Watches for active Zoom meetings via NSWorkspace polling.
///
/// Detection uses two signals, in order:
/// 1. `us.zoom.CptHost` process present — spawns at meeting start / tears down at leave.
///    (`us.zoom.caphost` spawns eagerly at Zoom launch, so it is NOT a meeting signal.)
/// 2. A `us.zoom.xos` window exists whose title is not the home screen.
///    Home screen titles are `Zoom` and `Zoom Workplace`; the meeting window itself is
///    titled `Zoom Meeting` when no topic is set (that counts as in-meeting).
@Observable
@MainActor
final class ZoomWatcher {
    /// True when a Zoom meeting is active.
    var inMeeting = false

    /// Bundles whose mere presence indicates an active meeting.
    private static let meetingProcessBundles: Set<String> = ["us.zoom.CptHost"]
    /// Bundles we inspect via AX for window titles.
    private static let titleBundles: Set<String> = ["us.zoom.xos", "us.zoom.caphost"]
    /// Home screen / splash window titles — not a real meeting.
    private static let homeTitles: Set<String> = ["zoom", "zoom workplace"]
    /// Titles that indicate a meeting but carry no topic (skip for display).
    private static let untitledMeetingTitles: Set<String> = ["zoom meeting"]

    private let logger = Logger(subsystem: "com.transcribeer", category: "zoom-watcher")
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
        let nowInMeeting = hasMeetingProcess() || hasMeetingWindow()
        if nowInMeeting != inMeeting {
            logger.info("inMeeting \(self.inMeeting, privacy: .public) -> \(nowInMeeting, privacy: .public)")
            inMeeting = nowInMeeting
        }
    }

    /// Fast check: any meeting-only Zoom helper process running?
    private func hasMeetingProcess() -> Bool {
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier,
               Self.meetingProcessBundles.contains(bundleID) {
                return true
            }
        }
        return false
    }

    /// Fallback: AX-inspect Zoom windows and treat any non-home title as a meeting.
    private func hasMeetingWindow() -> Bool {
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

                if !Self.homeTitles.contains(title.lowercased()) {
                    return true
                }
            }
        }
        return false
    }

    /// Attempt to read the Zoom meeting topic via AX. Returns nil if no topic is set
    /// (e.g. window titled just "Zoom Meeting").
    func meetingTitle() -> String? {
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
                      let rawTitle = titleRef as? String else { continue }
                if let cleaned = Self.cleanZoomTitle(rawTitle) {
                    return cleaned
                }
            }
        }
        return nil
    }

    static func cleanZoomTitle(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return nil }

        for suffix in [" - Zoom", " | Zoom", " — Zoom", " – Zoom"] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }

        let lower = title.lowercased()
        if title.isEmpty || homeTitles.contains(lower) || untitledMeetingTitles.contains(lower) {
            return nil
        }
        return title
    }
}
