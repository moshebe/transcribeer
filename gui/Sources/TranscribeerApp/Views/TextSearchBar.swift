import AppKit
import HighlightedTextEditor
import SwiftUI

/// Case-insensitive substring matching shared by the transcript and summary
/// find features. Kept deliberately simple — plain substring, no regex.
enum TextMatcher {
    /// Number of case-insensitive occurrences of `query` in `text`.
    static func count(of query: String, in text: String) -> Int {
        guard !query.isEmpty else { return 0 }
        var total = 0
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: query, options: .caseInsensitive, range: start..<text.endIndex) {
            total += 1
            start = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
        }
        return total
    }

    /// Builds an `AttributedString` with every occurrence of `query`
    /// highlighted. The `activeOccurrence`-th match (0-based) gets a stronger
    /// accent so the current find target stands out from the rest.
    static func highlighted(
        text: String,
        query: String,
        activeOccurrence: Int?
    ) -> AttributedString {
        guard !query.isEmpty else { return AttributedString(text) }
        var result = AttributedString()
        var cursor = text.startIndex
        var occurrence = 0
        while cursor < text.endIndex,
              let range = text.range(of: query, options: .caseInsensitive, range: cursor..<text.endIndex) {
            if cursor < range.lowerBound {
                result += AttributedString(String(text[cursor..<range.lowerBound]))
            }
            var match = AttributedString(String(text[range]))
            let isActive = occurrence == activeOccurrence
            match.backgroundColor = isActive ? .orange : Color.yellow.opacity(0.55)
            match.foregroundColor = .black
            result += match
            cursor = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
            occurrence += 1
        }
        if cursor < text.endIndex {
            result += AttributedString(String(text[cursor...]))
        }
        return result
    }
}

/// Applies find highlighting to an `NSTextView` using temporary layout
/// attributes, so it never mutates the backing text storage (safe for the
/// read-only summary source and the editable notes field alike). Shared by
/// the summary-source and notes editors.
enum SearchHighlighter {
    /// Applies highlighting on the next runloop tick. Deferring keeps the
    /// temporary-attribute writes and scroll off the current SwiftUI update
    /// cycle (which would otherwise warn about mutating during layout).
    static func applyDeferred(query: String, activeOccurrence: Int?, to textView: NSTextView) {
        DispatchQueue.main.async {
            apply(query: query, activeOccurrence: activeOccurrence, to: textView)
        }
    }

    static func apply(query: String, activeOccurrence: Int?, to textView: NSTextView) {
        guard let layout = textView.layoutManager else { return }
        let text = textView.string as NSString
        let full = NSRange(location: 0, length: text.length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        guard !query.isEmpty else { return }

        var searchRange = full
        var occurrence = 0
        while searchRange.length > 0 {
            let match = text.range(of: query, options: .caseInsensitive, range: searchRange)
            if match.location == NSNotFound { break }
            let isActive = occurrence == activeOccurrence
            layout.addTemporaryAttribute(
                .backgroundColor,
                value: isActive ? NSColor.systemOrange : NSColor.systemYellow.withAlphaComponent(0.5),
                forCharacterRange: match,
            )
            layout.addTemporaryAttribute(.foregroundColor, value: NSColor.black, forCharacterRange: match)
            if isActive { textView.scrollRangeToVisible(match) }
            let next = match.location + max(match.length, 1)
            if next >= text.length { break }
            searchRange = NSRange(location: next, length: text.length - next)
            occurrence += 1
        }
    }
}

/// Editable notes field backed by an `NSTextView` we can introspect, so the
/// same find highlighting used for the summary source works here too.
struct NotesEditor: View {
    @Binding var text: String
    var searchQuery: String = ""
    var activeOccurrence: Int?

    var body: some View {
        HighlightedTextEditor(text: $text, highlightRules: [])
            .introspect { editor in
                configure(editor.textView)
                SearchHighlighter.applyDeferred(
                    query: searchQuery, activeOccurrence: activeOccurrence, to: editor.textView,
                )
            }
    }

    private func configure(_ textView: NSTextView) {
        textView.font = .systemFont(ofSize: 13)
        textView.textContainerInset = NSSize(width: 16, height: 12)
        textView.drawsBackground = false
    }
}

/// Floating find bar shown on ⌘F over the transcript / summary content.
/// Owns no state — the hosting view drives query, match count and navigation.
struct FindBar: View {
    @Binding var query: String
    let matchCount: Int
    /// 0-based index of the current match, for the "n of m" label.
    let currentIndex: Int
    let onNext: () -> Void
    let onPrev: () -> Void
    let onClose: () -> Void
    @FocusState.Binding var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .frame(width: 180)
                .focused($focused)
                .onSubmit(onNext)

            Text(matchLabel)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 60, alignment: .trailing)

            Divider().frame(height: 16)

            Button(action: onPrev) { Image(systemName: "chevron.up") }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Previous match")
            Button(action: onNext) { Image(systemName: "chevron.down") }
                .keyboardShortcut("g", modifiers: .command)
                .help("Next match")
            Button(action: onClose) { Image(systemName: "xmark") }
                .keyboardShortcut(.cancelAction)
                .help("Close find")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.4)))
        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
        // Stay a compact pill in the corner — without this the greedy plain
        // TextField lets the whole bar stretch to the overlay's full width,
        // making it read as a second (redundant) search field.
        .fixedSize()
    }

    private var matchLabel: String {
        if query.isEmpty { return "" }
        if matchCount == 0 { return "No results" }
        return "\(currentIndex + 1) of \(matchCount)"
    }
}
