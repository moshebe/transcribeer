import AppKit
import ApplicationServices
import Foundation
import os

/// Reads the current Zoom meeting participants via the Accessibility API.
///
/// Passive / read-only: never opens, closes, or otherwise manipulates Zoom's UI.
/// When the participants side panel is closed, `lookup()` returns `.panelClosed`
/// and callers should keep using their last-known snapshot (or nothing).
///
/// Tree shape (confirmed via Accessibility Inspector, Zoom Workplace 2026.x):
/// ```
/// zoom.us (application)              [NSApplication]
/// └── Zoom Meeting (window)          [ZPConfMainWindow]
///     └── scroll area                [NSScrollView]
///         └── Participants list (outline) [ZMPlistOutlineView]
///             └── cell               [ZMPlistTableCellView]       ← one per participant
///                 ├── "Name Profile button"      (bubble)
///                 ├── "Name (Host, me)"          (static text)    ← primary label
///                 ├── "Unmute" / "Mute"          (button)         ← host-only
///                 ├── "More options for Name, collapsed" (button)
///                 ├── "Computer audio muted"     (image)
///                 └── "Video on" / "Video off"   (image)
/// ```
enum ZoomParticipantsReader {
    private static let logger = Logger(subsystem: "com.transcribeer", category: "zoom-participants")

    private static let zoomBundles: Set<String> = ["us.zoom.xos", "us.zoom.caphost"]

    /// Depth cap for descendant traversal — each Zoom meeting window is ~5 levels
    /// deep to the outline. 8 gives margin without runaway work.
    private static let maxTraversalDepth = 8

    // MARK: - Public API

    struct Participant: Equatable, Identifiable, Sendable {
        /// Position in the participants outline (0-based). Not stable across joins/leaves.
        let id: Int
        let displayName: String
        /// Raw AX label, preserved for debugging (`"Alice (Host, me)"`).
        let rawLabel: String
        let isMe: Bool
        let isHost: Bool
        let isCoHost: Bool
        let isGuest: Bool
        let isSpeaking: Bool
        let micState: MicState
        let videoState: VideoState
    }

    enum MicState: String, Equatable, Sendable {
        case unknown, muted, unmuted, phone, noAudio
    }

    enum VideoState: String, Equatable, Sendable {
        case unknown, on, off
    }

    struct Snapshot: Equatable, Sendable {
        let participants: [Participant]
        let readAt: Date
        var count: Int { participants.count }
    }

    /// Outcome of a single lookup attempt. Distinct cases let the watcher log
    /// transitions (`panelClosed → found(3) → panelClosed`) without noise.
    enum LookupState: Equatable, Sendable {
        case zoomNotRunning
        case noMeetingWindow
        case panelClosed
        case found(count: Int)
        case axError(String)

        var shortDescription: String {
            switch self {
            case .zoomNotRunning: "zoom-not-running"
            case .noMeetingWindow: "no-meeting-window"
            case .panelClosed: "panel-closed"
            case .found(let n): "found(\(n))"
            case .axError(let msg): "ax-error(\(msg))"
            }
        }
    }

    struct LookupResult: Sendable {
        let state: LookupState
        let snapshot: Snapshot?
    }

    /// Probe Zoom's AX tree once. Cheap enough to call on a 1–2 s poll.
    @MainActor
    static func lookup(now: () -> Date = Date.init) -> LookupResult {
        if !AXIsProcessTrusted() {
            logger.info("AX not trusted — cannot read zoom participants")
            return LookupResult(state: .axError("not-trusted"), snapshot: nil)
        }
        guard let zoomApp = runningZoom() else {
            return LookupResult(state: .zoomNotRunning, snapshot: nil)
        }

        let axApp = AXUIElementCreateApplication(zoomApp.processIdentifier)
        guard let windows = childElements(axApp, attribute: kAXWindowsAttribute as CFString),
              !windows.isEmpty
        else {
            return LookupResult(state: .noMeetingWindow, snapshot: nil)
        }

        var scanned = 0
        for window in windows {
            scanned += 1
            guard let outline = findFirstDescendant(window, matching: { roleOf($0) == kAXOutlineRole }) else {
                continue
            }
            let cells = collectCells(under: outline)
            let participants = cells.enumerated().compactMap { index, cell in
                parseCell(cell, index: index)
            }
            logger.debug(
                "participants outline matched (window \(scanned, privacy: .public)/\(windows.count, privacy: .public), cells=\(cells.count, privacy: .public), parsed=\(participants.count, privacy: .public))",
            )
            let snapshot = Snapshot(participants: participants, readAt: now())
            return LookupResult(state: .found(count: participants.count), snapshot: snapshot)
        }

        logger.debug("no participants outline in \(windows.count, privacy: .public) zoom window(s) — panel closed")
        return LookupResult(state: .panelClosed, snapshot: nil)
    }

    // MARK: - Parsed label (pure, for tests)

    struct ParsedLabel: Equatable, Sendable {
        let name: String
        let isMe: Bool
        let isHost: Bool
        let isCoHost: Bool
        let isGuest: Bool
        let isSpeaking: Bool
    }

    /// Parses the display label Zoom puts on the row's static-text field.
    ///
    /// Accepts formats like:
    /// - `"Alice Smith"`
    /// - `"Alice Smith (me)"`
    /// - `"Alice Smith (Host, me)"`
    /// - `"Alice Smith (Co-host)"`
    /// - `"Bob External (Guest)"`
    /// - `"Alice Smith (Host, me) (Speaking)"`
    ///
    /// A trailing `(…)` group is only stripped when **every** token inside is a
    /// recognized Zoom role tag. Unknown tags are treated as part of the user's
    /// display name (e.g. `"Dr. Smith (PhD)"` stays intact).
    static func parseLabel(_ raw: String) -> ParsedLabel {
        var remaining = raw.trimmingCharacters(in: .whitespaces)
        var flags = TagFlags()
        // Strip trailing "(…)" groups right-to-left while they parse as pure tag groups.
        for _ in 0..<4 {
            guard let open = remaining.lastIndex(of: "("),
                  remaining.hasSuffix(")"),
                  open > remaining.startIndex
            else { break }
            let inner = remaining[remaining.index(after: open)..<remaining.index(before: remaining.endIndex)]
            var candidate = TagFlags()
            guard candidate.applyIfAllKnown(inner) else { break }
            flags.merge(candidate)
            remaining = String(remaining[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return ParsedLabel(
            name: remaining,
            isMe: flags.isMe,
            isHost: flags.isHost,
            isCoHost: flags.isCoHost,
            isGuest: flags.isGuest,
            isSpeaking: flags.isSpeaking,
        )
    }

    private struct TagFlags {
        var isMe = false
        var isHost = false
        var isCoHost = false
        var isGuest = false
        var isSpeaking = false

        /// Returns `true` iff every token in `group` is a known tag. The flags
        /// are only set when the return value is `true`.
        mutating func applyIfAllKnown(_ group: Substring) -> Bool {
            let tokens = group.split(separator: ",")
            guard !tokens.isEmpty else { return false }
            for token in tokens {
                switch token.trimmingCharacters(in: .whitespaces).lowercased() {
                case "me": isMe = true
                case "host": isHost = true
                case "co-host", "cohost": isCoHost = true
                case "guest": isGuest = true
                case "speaking": isSpeaking = true
                default: return false
                }
            }
            return true
        }

        mutating func merge(_ other: Self) {
            isMe = isMe || other.isMe
            isHost = isHost || other.isHost
            isCoHost = isCoHost || other.isCoHost
            isGuest = isGuest || other.isGuest
            isSpeaking = isSpeaking || other.isSpeaking
        }
    }

    // MARK: - Cell parsing

    private static func parseCell(_ cell: AXUIElement, index: Int) -> Participant? {
        let descendants = collectDescendants(cell, maxDepth: 4)

        // Primary name source: first AXStaticText under the cell. Zoom sets the
        // display label on either AXValue or AXTitle depending on build; try both.
        let rawLabel = descendants
            .first { roleOf($0) == kAXStaticTextRole }
            .flatMap { staticText in
                stringAttr(staticText, attribute: kAXValueAttribute as CFString)
                    ?? stringAttr(staticText, attribute: kAXTitleAttribute as CFString)
            } ?? ""

        guard !rawLabel.isEmpty else {
            logger.debug("skipping cell #\(index, privacy: .public): no static-text label")
            return nil
        }

        let parsed = parseLabel(rawLabel)
        var micState = MicState.unknown
        var videoState = VideoState.unknown

        for descendant in descendants where roleOf(descendant) == kAXImageRole {
            let description = stringAttr(descendant, attribute: kAXDescriptionAttribute as CFString)
                ?? stringAttr(descendant, attribute: kAXTitleAttribute as CFString)
                ?? ""
            if let state = micStateFromDescription(description) { micState = state }
            if let state = videoStateFromDescription(description) { videoState = state }
        }

        return Participant(
            id: index,
            displayName: parsed.name,
            rawLabel: rawLabel,
            isMe: parsed.isMe,
            isHost: parsed.isHost,
            isCoHost: parsed.isCoHost,
            isGuest: parsed.isGuest,
            isSpeaking: parsed.isSpeaking,
            micState: micState,
            videoState: videoState,
        )
    }

    /// Extracts mic state from an AXImage description (e.g. "Computer audio muted").
    static func micStateFromDescription(_ description: String) -> MicState? {
        let lower = description.lowercased()
        guard lower.contains("audio") else { return nil }
        if lower.contains("telephone") || lower.contains("phone") { return .phone }
        if lower.contains("no audio") { return .noAudio }
        if lower.contains("unmuted") { return .unmuted }
        if lower.contains("muted") { return .muted }
        return nil
    }

    /// Extracts video on/off from an AXImage description (e.g. "Video on" / "Video off").
    static func videoStateFromDescription(_ description: String) -> VideoState? {
        let lower = description.lowercased()
        guard lower.hasPrefix("video ") else { return nil }
        if lower.contains(" off") { return .off }
        if lower.contains(" on") { return .on }
        return nil
    }

    // MARK: - AX traversal helpers

    private static func runningZoom() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { app in
            zoomBundles.contains(app.bundleIdentifier ?? "")
        }
    }

    private static func roleOf(_ element: AXUIElement) -> String {
        stringAttr(element, attribute: kAXRoleAttribute as CFString) ?? ""
    }

    private static func stringAttr(_ element: AXUIElement, attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func childElements(_ element: AXUIElement, attribute: CFString) -> [AXUIElement]? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? [AXUIElement]
    }

    /// BFS for the first descendant that satisfies `predicate`. Returns `nil` if
    /// the subtree exceeds `maxTraversalDepth` without a match.
    private static func findFirstDescendant(
        _ root: AXUIElement,
        matching predicate: (AXUIElement) -> Bool,
    ) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            if depth > 0, predicate(element) { return element }
            guard depth < maxTraversalDepth,
                  let kids = childElements(element, attribute: kAXChildrenAttribute as CFString)
            else { continue }
            for kid in kids { queue.append((kid, depth + 1)) }
        }
        return nil
    }

    /// Collect the outline's participant cells. Accepts both direct `AXCell`
    /// children (current Zoom build) and `AXRow → AXCell` (older / future).
    private static func collectCells(under outline: AXUIElement) -> [AXUIElement] {
        guard let children = childElements(outline, attribute: kAXChildrenAttribute as CFString) else {
            return []
        }
        var cells: [AXUIElement] = []
        for child in children {
            switch roleOf(child) {
            case kAXCellRole:
                cells.append(child)
            case kAXRowRole:
                if let rowKids = childElements(child, attribute: kAXChildrenAttribute as CFString) {
                    cells.append(contentsOf: rowKids.filter { roleOf($0) == kAXCellRole })
                }
            default:
                continue
            }
        }
        return cells
    }

    /// Flat list of descendants up to `maxDepth`, root excluded. Order matches BFS.
    private static func collectDescendants(_ root: AXUIElement, maxDepth: Int) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        while !queue.isEmpty {
            let (element, depth) = queue.removeFirst()
            if depth > 0 { result.append(element) }
            guard depth < maxDepth,
                  let kids = childElements(element, attribute: kAXChildrenAttribute as CFString)
            else { continue }
            for kid in kids { queue.append((kid, depth + 1)) }
        }
        return result
    }
}
