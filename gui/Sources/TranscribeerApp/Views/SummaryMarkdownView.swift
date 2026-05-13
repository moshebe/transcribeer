import AppKit
import HighlightedTextEditor
import MarkdownUI
import SwiftUI

/// Renders the session summary. Defaults to a rich-text render that hides
/// the raw markdown syntax (`#`, `**`, list markers, etc.); a small toolbar
/// toggle swaps in a source view — `HighlightedTextEditor` with the
/// `.markdown` preset — for copying or inspecting the underlying markup.
///
/// Layout flips right-to-left when the dominant script is RTL.
struct SummaryMarkdownView: View {
    let text: String

    @State private var showSource = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Apply the RTL flip to the content only — keep the toggle
            // button pinned to the top-right corner regardless of script.
            // Setting `layoutDirection` on a `Group` wrapper didn't always
            // propagate into `MarkdownUI`'s nested `BlockSequence` / `Text`
            // views (bullets and headings stayed LTR). Pushing the
            // environment directly onto each branch — and also onto the
            // inner `Markdown` view — is what actually flips block-level
            // layout, list markers and paragraph alignment.
            Group {
                if showSource {
                    sourceView
                } else {
                    richView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            toggleButton
                .padding(8)
        }
    }

    /// Any Hebrew/Arabic/etc. character flips the whole summary to RTL.
    /// Summaries routinely mix Latin technical terms into RTL prose; a
    /// strict majority vote leaves them rendered LTR, which is what the
    /// previous implementation got wrong.
    private var isRTL: Bool { TextDirection.containsRightToLeft(text) }

    private var layoutDirection: LayoutDirection { isRTL ? .rightToLeft : .leftToRight }

    /// Pair the layout flip with a Hebrew locale so SwiftUI's natural
    /// alignment heuristics (and any locale-aware bidi defaults) line up
    /// with what we're forcing visually.
    private var locale: Locale { isRTL ? Locale(identifier: "he") : .current }

    private var richView: some View {
        ScrollView {
            Markdown(text)
                .markdownTextStyle(\.text) {
                    FontSize(13)
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                // `.leading` under an RTL env resolves to the right edge,
                // which is what we want for Hebrew. Using `.trailing` would
                // flush wrapped lines to the left.
                .multilineTextAlignment(.leading)
                .environment(\.layoutDirection, layoutDirection)
                .environment(\.locale, locale)
                .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.layoutDirection, layoutDirection)
        .environment(\.locale, locale)
    }

    private var sourceView: some View {
        HighlightedTextEditor(text: readonlyBinding, highlightRules: .markdown)
            .introspect { editor in configure(editor.textView) }
            .background(Color(nsColor: .textBackgroundColor))
            .environment(\.layoutDirection, layoutDirection)
            .environment(\.locale, locale)
    }

    private var toggleButton: some View {
        Button {
            showSource.toggle()
        } label: {
            Image(systemName: showSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.borderless)
        .background(.regularMaterial, in: Circle())
        .overlay(Circle().strokeBorder(Color.secondary.opacity(0.2)))
        .help(showSource ? "Show rendered markdown" : "Show markdown source")
        .accessibilityLabel(showSource ? "Show rendered markdown" : "Show markdown source")
    }

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
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = false
        textView.textContainer?.lineFragmentPadding = 0
    }
}
