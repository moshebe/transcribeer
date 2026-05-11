import SwiftUI

/// Small coloured pill used by every Settings status row. Module-internal so
/// the transcription tab and the summarization tab can both render badges
/// without duplicating styling.
struct SettingsBadgeStyle: ViewModifier {
    let tint: Color
    var font: Font = .caption2

    func body(content: Content) -> some View {
        content
            .font(font)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.18), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// Status icon used by every Summarization / Transcription status row.
/// Centralising the icon/colour mapping keeps status views visually
/// consistent and ensures every icon carries an explicit accessibility label.
struct SettingsStatusIcon: View {
    enum Kind { case loading, ok, warning, error }

    let kind: Kind
    let accessibilityLabel: String

    var body: some View {
        Group {
            switch kind {
            case .loading:
                ProgressView().controlSize(.mini)
            case .ok:
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .error:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }
}
