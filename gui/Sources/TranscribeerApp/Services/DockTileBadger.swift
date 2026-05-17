import AppKit

/// Overlays a red recording dot on the Dock tile while recording.
///
/// The app is `LSUIElement` so the Dock tile is only visible when
/// `DockVisibility` has promoted the activation policy to `.regular`
/// (i.e. a user-facing window is open). Setting `NSApp.applicationIconImage`
/// is still safe when hidden — macOS picks up the assigned image the moment
/// the Dock tile becomes visible.
@MainActor
enum DockTileBadger {
    /// Cached un-badged icon, loaded on first apply. Matches whatever
    /// `AppDelegate.configureAppIcon()` installed.
    private static var baseIcon: NSImage?

    static func register(baseIcon: NSImage) {
        Self.baseIcon = baseIcon
    }

    /// Toggles the red-dot overlay on the Dock tile.
    static func setRecording(_ recording: Bool) {
        guard let base = baseIcon else { return }
        NSApp.applicationIconImage = RecordingIndicatorRenderer.dockImage(
            base: base,
            recording: recording,
        )
    }
}
