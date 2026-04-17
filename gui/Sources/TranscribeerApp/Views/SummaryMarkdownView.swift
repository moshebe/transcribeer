import AppKit
import HighlightedTextEditor
import SwiftUI

/// Renders the session summary as live-highlighted markdown, read-only,
/// with right-to-left layout when the dominant script is RTL (Hebrew,
/// Arabic, etc.). Reuses `HighlightedTextEditor`'s `.markdown` preset so
/// headings / bold / lists get the same treatment as the prompt editor.
///
/// A non-optional `Binding` is required by `HighlightedTextEditor`, but
/// we swallow writes because the underlying `NSTextView` is configured
/// `isEditable = false`.
///
/// Streaming progress is shown by the controls row above this view —
/// this one just keeps re-rendering the latest accumulator.
struct SummaryMarkdownView: View {
    let text: String

    var body: some View {
        HighlightedTextEditor(text: readonlyBinding, highlightRules: .markdown)
            .introspect { editor in configure(editor.textView) }
            .background(Color(nsColor: .textBackgroundColor))
    }

    private var isRTL: Bool { TextDirection.isRightToLeft(text) }

    /// `HighlightedTextEditor` requires a two-way binding. The `get` pins
    /// to the latest `text` so streaming updates propagate; writes are
    /// ignored because `isEditable` is `false`.
    private var readonlyBinding: Binding<String> {
        Binding(get: { text }, set: { _ in })
    }

    private func configure(_ textView: NSTextView) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.baseWritingDirection = isRTL ? .rightToLeft : .leftToRight
        textView.alignment = isRTL ? .right : .left
        // Keep link detection so `[label](url)` opens on click without an
        // explicit delegate.
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = false
        textView.textContainer?.lineFragmentPadding = 0
    }
}
