import Foundation

// MARK: - Meeting App Detection

/// A running application that may host meetings.
struct MeetingApp: Sendable, Hashable, Codable {
    let bundleID: String
    let name: String
}

/// A single entry in the known-apps table.
struct MeetingAppEntry: Sendable, Hashable {
    let bundleID: String
    let displayName: String
    /// Bundle ID of the process whose termination signals that the meeting is over.
    /// When `nil`, falls back to `bundleID` (end = user quit the whole app).
    ///
    /// Example: Zoom's main app (`us.zoom.xos`) can stay running after a call ends;
    /// the meeting-only helper (`us.zoom.CptHost`) exits the instant you leave. Watching
    /// the helper gives a precise "meeting over" signal.
    let endProcessBundleID: String?

    init(bundleID: String, displayName: String, endProcessBundleID: String? = nil) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.endProcessBundleID = endProcessBundleID
    }

    /// Process to watch for termination — `endProcessBundleID` if set, else `bundleID`.
    var effectiveEndProcessBundleID: String {
        endProcessBundleID ?? bundleID
    }
}

// MARK: - Detection Trigger

/// Tracks which signal is keeping detection active.
enum MeetingDetectionTrigger: Sendable, Equatable {
    case camera
    case micAndApp
}
