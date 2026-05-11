/// Supported transcription backends.
///
/// `whisperkit` runs WhisperKit locally on the Apple Neural Engine.
/// `openai` and `gemini` call cloud APIs that take an audio file and return
/// segmented text. They reuse `KeychainHelper` for API keys (same slot as
/// summarization for `openai`, dedicated slot for `gemini`).
enum TranscriptionBackend: String, CaseIterable, Identifiable, Sendable {
    case whisperkit
    case openai
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperkit: "Local (WhisperKit)"
        case .openai: "OpenAI"
        case .gemini: "Gemini"
        }
    }

    /// Whether this backend authenticates with an API key stored in the
    /// Keychain (or read from an environment variable as a fallback).
    var usesAPIKey: Bool {
        switch self {
        case .whisperkit: false
        case .openai, .gemini: true
        }
    }

    /// Keychain service slot — matches `LLMBackend.openai` so users only
    /// configure their OpenAI key once. Gemini uses its own slot because the
    /// summarization side authenticates via gcloud ADC and has no key.
    var keychainKey: String {
        switch self {
        case .whisperkit: ""
        case .openai: "openai"
        case .gemini: "gemini"
        }
    }

    /// Environment variable consulted when the Keychain is empty.
    /// `GOOGLE_API_KEY` is checked as an additional fallback for Gemini in
    /// `CloudTranscriptionService` — keep the picker label deterministic.
    var envVar: String? {
        switch self {
        case .whisperkit: nil
        case .openai: "OPENAI_API_KEY"
        case .gemini: "GEMINI_API_KEY"
        }
    }

    /// Default model when this backend is selected for the first time.
    /// `whisper-1` is the only OpenAI audio model that returns segment-level
    /// timestamps via `verbose_json`. `gemini-2.5-flash` accepts audio and
    /// supports structured-output mode for timestamped segments.
    var defaultModel: String {
        switch self {
        case .whisperkit: "openai_whisper-large-v3_turbo"
        case .openai: "whisper-1"
        case .gemini: "gemini-2.5-flash"
        }
    }

    /// Parse a persisted config string, falling back to `.whisperkit` so a
    /// typo never breaks transcription.
    static func from(_ raw: String) -> Self {
        Self(rawValue: raw) ?? .whisperkit
    }
}
