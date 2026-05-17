import AppKit

/// Produces `NSImage`s for the menu-bar label and the Dock tile that
/// overlay a red "recording" dot on top of a base icon.
///
/// Why this exists:
/// * `MenuBarExtra`'s SwiftUI label only respects plain `Image`/`Text`; any
///   `ZStack`/overlay/`foregroundStyle` is silently dropped, so the naive
///   `Circle().fill(.red)` overlay in SwiftUI never makes it onto the
///   menu bar. We have to hand off a fully-composited `NSImage`.
/// * Dock tiles don't auto-tint or badge for us; we composite the base
///   app icon + dot ourselves and assign to `NSApp.applicationIconImage`.
@MainActor
enum RecordingIndicatorRenderer {
    // MARK: - Menu bar

    /// Renders the menu-bar icon for the given state.
    ///
    /// Idle/transcribing/done/error states return a template image so
    /// macOS tints it to the menu bar's foreground color automatically.
    /// Recording state composites a red dot on top and returns a
    /// non-template image (template is all-or-nothing, so once we need
    /// a specific color anywhere we must render the whole thing).
    static func menuBarImage(state: AppState, isDevBuild: Bool) -> NSImage {
        let symbolName = baseSymbolName(for: state)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return NSImage()
        }

        // Fast path: monochrome template, let macOS tint.
        if !state.isRecording && !isDevBuild {
            symbol.isTemplate = true
            return symbol
        }

        // Composite path: we need colored pixels (red dot, orange dev "D"),
        // so we manually tint the base symbol and draw overlays.
        let size = NSSize(
            width: ceil(symbol.size.width) + 4,
            height: ceil(symbol.size.height) + 2,
        )
        let composed = NSImage(size: size)
        composed.lockFocusFlipped(false)
        defer {
            composed.unlockFocus()
            composed.isTemplate = false
        }

        let symbolRect = NSRect(
            x: (size.width - symbol.size.width) / 2,
            y: (size.height - symbol.size.height) / 2,
            width: symbol.size.width,
            height: symbol.size.height,
        )
        drawTintedTemplate(symbol, in: symbolRect, color: menuBarForegroundColor())

        if state.isRecording {
            let dotDiameter: CGFloat = 6
            let dotRect = NSRect(
                x: size.width - dotDiameter - 0.5,
                y: size.height - dotDiameter - 0.5,
                width: dotDiameter,
                height: dotDiameter,
            )
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }

        if isDevBuild {
            drawDevBadge(in: size)
        }

        return composed
    }

    // MARK: - Dock tile

    /// Produces a badged dock icon for recording state. When `recording`
    /// is false the base icon is returned unchanged.
    static func dockImage(base: NSImage, recording: Bool) -> NSImage {
        guard recording else { return base }

        let size = base.size
        let composed = NSImage(size: size)
        composed.lockFocusFlipped(false)
        defer { composed.unlockFocus() }

        base.draw(in: NSRect(origin: .zero, size: size))

        // Dot sized relative to the icon so it scales with retina variants.
        let dotDiameter = size.width * 0.28
        let margin = size.width * 0.06
        let dotRect = NSRect(
            x: size.width - dotDiameter - margin,
            y: size.height - dotDiameter - margin,
            width: dotDiameter,
            height: dotDiameter,
        )

        // White halo so the dot reads against any icon background.
        NSColor.white.setFill()
        let halo = dotRect.insetBy(dx: -2, dy: -2)
        NSBezierPath(ovalIn: halo).fill()

        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        return composed
    }

    // MARK: - Helpers

    private static func baseSymbolName(for state: AppState) -> String {
        switch state {
        case .idle, .recording: "mic"
        case .transcribing, .summarizing: "ellipsis.circle"
        case .done: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    private static func menuBarForegroundColor() -> NSColor {
        let appearance = NSApp.effectiveAppearance
        let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
        let isDark = match == .darkAqua || match == .vibrantDark
        return isDark ? .white : .black
    }

    /// Draws a template-style monochrome image tinted with the given color.
    private static func drawTintedTemplate(_ image: NSImage, in rect: NSRect, color: NSColor) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }

        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
        color.set()
        rect.fill(using: .sourceAtop)
    }

    private static func drawDevBadge(in size: NSSize) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .heavy),
            .foregroundColor: NSColor.systemOrange,
            .paragraphStyle: paragraph,
        ]
        let string = NSAttributedString(string: "D", attributes: attributes)
        // Bottom-right corner. NSImage origin is bottom-left (non-flipped).
        let textRect = NSRect(x: 0, y: 0, width: size.width - 1, height: 9)
        string.draw(in: textRect)
    }
}
