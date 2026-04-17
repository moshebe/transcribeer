import Foundation

/// Supported transcription languages. We only expose the ones the user
/// records in — auto-detect is still available but costs a language-ID
/// pass before every chunk, so an explicit choice is faster.
enum TranscriptionLanguage: String, CaseIterable, Identifiable, Hashable {
    case auto
    case english = "en"
    case hebrew = "he"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "Auto-detect"
        case .english: "English"
        case .hebrew: "Hebrew"
        }
    }

    /// Compact uppercase code (`"EN"`, `"HE"`) for badges. `auto` returns `nil`
    /// so callers can hide the badge when no language is committed.
    var badgeText: String? {
        switch self {
        case .auto: nil
        case .english, .hebrew: rawValue.uppercased()
        }
    }

    /// Parse a config value back into an enum case. Anything unrecognised
    /// falls back to `auto` so legacy configs keep working.
    static func from(_ raw: String) -> Self {
        Self(rawValue: raw) ?? .auto
    }

    /// The value passed to WhisperKit's `DecodingOptions.language`.
    /// `nil` means auto-detect; a two-letter code forces that language.
    var whisperCode: String? {
        self == .auto ? nil : rawValue
    }
}
