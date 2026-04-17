import AppKit

/// Tracks visible windows that should promote the app to a regular (Dock-visible)
/// activation policy. The app is an `LSUIElement` menubar app by default; we flip
/// to `.regular` while user-facing windows (like History) are open so they appear
/// in the Dock and ⌘-Tab switcher.
@MainActor
enum DockVisibility {
    private static var windowCount = 0

    /// Call from `.onAppear` of a user-facing window.
    static func windowDidAppear() {
        windowCount += 1
        applyPolicy()
    }

    /// Call from `.onDisappear` of a user-facing window.
    static func windowDidDisappear() {
        windowCount = max(0, windowCount - 1)
        applyPolicy()
    }

    private static func applyPolicy() {
        let desired: NSApplication.ActivationPolicy = windowCount > 0 ? .regular : .accessory
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
        if desired == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
