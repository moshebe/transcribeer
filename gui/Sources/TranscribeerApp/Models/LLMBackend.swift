import Foundation

/// Supported summarization backends.
///
/// Single source of truth for the Settings picker, `SummarizationService`,
/// `AppConfig` persistence, and the API-key status pill.
enum LLMBackend: String, CaseIterable, Identifiable, Sendable {
    case ollama
    case openai
    case anthropic
    case gemini

    var id: String { rawValue }
    var displayName: String { rawValue }

    /// Environment variable checked as a fallback for the API key when the
    /// Keychain is empty. `nil` for backends that don't use an API key.
    var envVar: String? {
        switch self {
        case .openai: "OPENAI_API_KEY"
        case .anthropic: "ANTHROPIC_API_KEY"
        case .gemini, .ollama: nil
        }
    }

    /// How this backend authenticates at runtime.
    enum AuthMode: Equatable, Sendable {
        case apiKey            // openai, anthropic
        case gcloudADC         // gemini (via `gcloud auth application-default`)
        case localEndpoint     // ollama
    }

    var auth: AuthMode {
        switch self {
        case .openai, .anthropic: .apiKey
        case .gemini: .gcloudADC
        case .ollama: .localEndpoint
        }
    }

    /// Parse a persisted config string, falling back to `.ollama` for unknown
    /// values so a typo in config.toml never crashes the app.
    static func from(_ raw: String) -> Self {
        Self(rawValue: raw) ?? .ollama
    }
}
