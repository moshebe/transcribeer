import AppKit
import ApplicationServices
import os

/// Reads the current Zoom meeting topic via the Accessibility API.
///
/// Temporary stand-in for the forthcoming generic meeting-title enricher system.
/// Only understands Zoom today — other apps fall back to the detected app name.
///
/// Zoom's window `AXTitle` is the generic constant `"Zoom Meeting"` in modern
/// builds, so the real topic must be sourced from a title-bar `AXButton` child
/// with `AXIdentifier == "MeetingTopBarInfoButton"`. In current builds that
/// button exposes the topic via `AXDescription` (`AXTitle` is empty); older
/// builds used `AXTitle`. We try both, and only fall back to the legacy
/// window-title path for popped-out or very old windows.
enum ZoomTitleReader {
    private static let logger = Logger(subsystem: "com.transcribeer", category: "zoom-title")
    private static let zoomBundles: Set<String> = ["us.zoom.xos", "us.zoom.caphost"]
    private static let homeTitles: Set<String> = ["zoom", "zoom workplace"]
    private static let untitledMeetingTitles: Set<String> = ["zoom meeting"]

    /// AX identifiers Zoom has used for the title-bar meeting info button
    /// across builds. We trust the description attribute only when one of
    /// these identifiers is present, to avoid picking up control buttons
    /// whose descriptions parse as plausible topics.
    static let meetingInfoButtonIdentifiers: Set<String> = [
        "MeetingTopBarInfoButton",
        "ZMMeetingInfoButton",
    ]

    /// In-meeting control buttons (English labels) that may appear as direct
    /// children of the meeting window in some layouts. Never valid as a meeting
    /// topic. Match is case-insensitive on the exact button title.
    private static let controlButtonTitles: Set<String> = [
        "mute", "unmute",
        "start video", "stop video",
        "participants", "chat", "share screen", "stop share",
        "reactions", "record", "pause record", "resume record",
        "more", "view", "settings",
        "leave", "end", "end meeting", "leave meeting",
        "breakout rooms", "apps", "whiteboard", "notes", "closed caption",
    ]

    /// Depth cap for descendant traversal when scanning for the title button.
    /// The button sits directly on the window in current builds; 4 gives us
    /// margin if Zoom ever nests it under a toolbar group.
    private static let maxTraversalDepth = 4

    /// Attempt to read the Zoom meeting topic. Returns `nil` if Zoom is not running,
    /// AX is not granted, no meeting window is open, or the meeting has no set topic.
    @MainActor
    static func meetingTitle() -> String? {
        if !AXIsProcessTrusted() {
            logger.info("AX not trusted — cannot read zoom title")
            return nil
        }

        var sawZoom = false
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  zoomBundles.contains(bundleID)
            else { continue }
            sawZoom = true

            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows = copyChildren(axApp, attribute: kAXWindowsAttribute as CFString) else {
                logger.debug("zoom (\(bundleID, privacy: .public)) has no AX windows")
                continue
            }

            for (index, window) in windows.enumerated() {
                let winTitle = copyString(window, attribute: kAXTitleAttribute as CFString) ?? ""
                if let fromButton = titleFromInfoButton(in: window) {
                    logger.info(
                        "title via info-button in window[\(index, privacy: .public)]='\(winTitle, privacy: .public)' → '\(fromButton, privacy: .public)'",
                    )
                    return fromButton
                }
                if let cleaned = cleanTitle(winTitle) {
                    logger.info(
                        "title via window-title fallback window[\(index, privacy: .public)]='\(winTitle, privacy: .public)' → '\(cleaned, privacy: .public)'",
                    )
                    return cleaned
                }
                logger.debug(
                    "no title in window[\(index, privacy: .public)]='\(winTitle, privacy: .public)'",
                )
            }
        }
        if !sawZoom {
            logger.debug("zoom not running — no title")
        } else {
            logger.debug("zoom running but no meeting topic found")
        }
        return nil
    }

    // MARK: - Button-based title

    /// Find the first `AXButton` descendant of `window` whose attributes parse
    /// as a meeting topic. For buttons whose `AXIdentifier` matches a known
    /// meeting-info button, description is consulted when title is absent.
    @MainActor
    private static func titleFromInfoButton(in window: AXUIElement) -> String? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var buttonCount = 0
        var sawKnownIdentifier = false
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            if depth > 0,
               copyString(element, attribute: kAXRoleAttribute as CFString) == kAXButtonRole {
                buttonCount += 1
                let title = copyString(element, attribute: kAXTitleAttribute as CFString)
                let description = copyString(element, attribute: kAXDescriptionAttribute as CFString)
                let identifier = copyString(element, attribute: "AXIdentifier" as CFString)
                if let identifier,
                   meetingInfoButtonIdentifiers.contains(identifier) {
                    sawKnownIdentifier = true
                    logger.debug(
                        "info-button found id=\(identifier, privacy: .public) t='\(title ?? "", privacy: .public)' d='\(description ?? "", privacy: .public)'",
                    )
                }
                if let accepted = extractInfoButtonTopic(
                    title: title,
                    description: description,
                    identifier: identifier,
                ) {
                    return accepted
                }
            }
            guard depth < maxTraversalDepth,
                  let kids = copyChildren(element, attribute: kAXChildrenAttribute as CFString)
            else { continue }
            for kid in kids { queue.append((kid, depth + 1)) }
        }
        logger.debug(
            "info-button BFS exhausted: scanned \(buttonCount, privacy: .public) button(s), knownID=\(sawKnownIdentifier, privacy: .public)",
        )
        return nil
    }

    /// Pure selection from an `AXButton`'s attributes, extracted for unit tests.
    ///
    /// - Any button: accept when `AXTitle` parses as a topic.
    /// - Known meeting-info buttons (by `AXIdentifier`): additionally accept
    ///   `AXDescription` when title is empty / rejected. Current Zoom builds
    ///   expose the topic here with an empty `AXTitle`.
    static func extractInfoButtonTopic(
        title: String?,
        description: String?,
        identifier: String?,
    ) -> String? {
        if let title, let accepted = acceptInfoButtonTitle(title) { return accepted }
        let isKnownInfoButton = identifier.map(meetingInfoButtonIdentifiers.contains) ?? false
        if isKnownInfoButton,
           let description,
           let accepted = acceptInfoButtonTitle(description) {
            return accepted
        }
        return nil
    }

    /// Pure predicate, extracted for unit tests: decides whether an `AXButton`
    /// title is a plausible meeting topic. Returns the trimmed title on accept,
    /// `nil` on reject.
    static func acceptInfoButtonTitle(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if controlButtonTitles.contains(lower) { return nil }
        if homeTitles.contains(lower) { return nil }
        // The bare string "Zoom Meeting" without a possessive prefix conveys
        // nothing useful — reject and let the fallback handle it.
        if untitledMeetingTitles.contains(lower) { return nil }
        return trimmed
    }

    // MARK: - AX helpers

    private static func copyString(_ element: AXUIElement, attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func copyChildren(_ element: AXUIElement, attribute: CFString) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? [AXUIElement]
    }

    private static let zoomSuffixes = [" - Zoom", " | Zoom", " — Zoom", " – Zoom"]

    /// Trims Zoom suffixes and filters out home-screen / untitled meeting window titles.
    static func cleanTitle(_ raw: String) -> String? {
        var title = raw.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }

        if let suffix = zoomSuffixes.first(where: title.hasSuffix) {
            title = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }

        let lower = title.lowercased()
        guard !title.isEmpty,
              !homeTitles.contains(lower),
              !untitledMeetingTitles.contains(lower)
        else { return nil }
        return title
    }
}
