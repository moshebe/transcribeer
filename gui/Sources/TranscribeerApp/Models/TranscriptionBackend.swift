/// Supported transcription backends.
///
/// `whisperkit` runs WhisperKit locally on the Apple Neural Engine.
/// `speechAnalyzer` runs Apple's SpeechAnalyzer / SpeechTranscriber (macOS 26+)
/// fully on-device. Faster and more accurate than WhisperKit for the
/// locales it supports, but does not include Hebrew.
/// `openai` and `gemini` call cloud APIs that take an audio file and return
/// segmented text. They reuse `KeychainHelper` for API keys (same slot as
/// summarization for `openai`, dedicated slot for `gemini`).
enum TranscriptionBackend: String, CaseIterable, Identifiable, Sendable {
    case whisperkit
    case speechAnalyzer = "speech_analyzer"
    case openai
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperkit: "Local (WhisperKit)"
        case .speechAnalyzer: "Apple SpeechAnalyzer (macOS 26+)"
        case .openai: "OpenAI"
        case .gemini: "Gemini"
        }
    }

    /// Whether this backend authenticates with an API key stored in the
    /// Keychain (or read from an environment variable as a fallback).
    var usesAPIKey: Bool {
        switch self {
        case .whisperkit, .speechAnalyzer: false
        case .openai, .gemini: true
        }
    }

    /// Whether this backend runs fully on-device (no network required).
    var isLocal: Bool {
        switch self {
        case .whisperkit, .speechAnalyzer: true
        case .openai, .gemini: false
        }
    }

    /// Keychain service slot — matches `LLMBackend.openai` so users only
    /// configure their OpenAI key once. Gemini uses its own slot because the
    /// summarization side authenticates via gcloud ADC and has no key.
    var keychainKey: String {
        switch self {
        case .whisperkit, .speechAnalyzer: ""
        case .openai: "openai"
        case .gemini: "gemini"
        }
    }

    /// Environment variable consulted when the Keychain is empty.
    /// `GOOGLE_API_KEY` is checked as an additional fallback for Gemini in
    /// `CloudTranscriptionService` — keep the picker label deterministic.
    var envVar: String? {
        switch self {
        case .whisperkit, .speechAnalyzer: nil
        case .openai: "OPENAI_API_KEY"
        case .gemini: "GEMINI_API_KEY"
        }
    }

    /// Parse a persisted config string, falling back to `.whisperkit` so a
    /// typo never breaks transcription.
    static func from(_ raw: String) -> Self {
        Self(rawValue: raw) ?? .whisperkit
    }
}
