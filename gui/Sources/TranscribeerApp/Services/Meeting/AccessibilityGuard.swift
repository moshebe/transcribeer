import AppKit
import ApplicationServices

/// Thin wrapper around the macOS Accessibility-permission API so call sites
/// don't have to juggle `AXIsProcessTrustedWithOptions` and System Settings
/// URLs directly.
///
/// The Zoom enrichers (`ZoomTitleReader`, `ZoomParticipantsReader`) silently
/// fail without this permission; UI surfaces use `isTrusted` to render a
/// prominent nudge so users can resolve it without opening Console.
enum AccessibilityGuard {
    /// Whether the current process is trusted to read other apps' AX trees.
    /// Cheap — safe to call on every view render / menu open.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask macOS to display the standard Accessibility permission prompt.
    /// Returns the trust status as observed at call time (the prompt is
    /// asynchronous, so `false` is expected on the first click).
    @discardableResult
    static func prompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Open System Settings directly on the Privacy → Accessibility pane.
    /// Paired with `prompt()` so users have a one-click path when the
    /// prompt dialog has already been dismissed.
    static func openSystemSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
