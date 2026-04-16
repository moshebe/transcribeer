import Foundation
import LLM

/// Summarizes transcripts via OpenAI, Anthropic, or Ollama.
public enum SummarizationService {
    public static let defaultPrompt = """
        You are a meeting summarizer. Given a meeting transcript with speaker \
        labels and timestamps, produce a concise summary in the same language \
        as the transcript. Include:
        - 2-3 sentence overview
        - Key decisions made
        - Action items (who, what)
        - Open questions

        Respond in markdown.
        """

    /// Summarize a transcript using the configured LLM backend.
    public static func summarize(
        transcript: String,
        backend: String,
        model: String,
        ollamaHost: String = "http://localhost:11434",
        prompt: String? = nil
    ) async throws -> String {
        let systemPrompt = prompt ?? defaultPrompt

        let provider: LLM.Provider = switch backend {
        case "openai":
            .openAI(apiKey: try requireKey("openai", env: "OPENAI_API_KEY"))
        case "anthropic":
            .anthropic(apiKey: try requireKey("anthropic", env: "ANTHROPIC_API_KEY"))
        case "ollama":
            .other(
                URL(string: "\(ollamaHost)/v1")!,
                apiKey: nil
            )
        default:
            throw SummarizationError.unknownBackend(backend)
        }

        let llm = LLM(provider: provider)
        let config = LLM.ChatConfiguration(
            systemPrompt: systemPrompt,
            user: transcript,
            modelType: .fast,
            inference: .direct,
            model: .init(rawValue: model)
        )
        return try await llm.chat(configuration: config)
    }

    /// Load a prompt profile from ~/.transcribeer/prompts/<name>.md.
    /// Returns nil if the file doesn't exist or name is nil/"default".
    public static func loadPromptProfile(_ name: String?) -> String? {
        guard let name, name != "default" else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/prompts/\(name).md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func requireKey(_ backend: String, env envVar: String) throws -> String {
        if let key = KeychainHelper.getAPIKey(backend: backend), !key.isEmpty {
            return key
        }
        if let key = ProcessInfo.processInfo.environment[envVar], !key.isEmpty {
            return key
        }
        throw SummarizationError.missingAPIKey(backend, envVar)
    }
}

public enum SummarizationError: LocalizedError {
    case unknownBackend(String)
    case missingAPIKey(String, String)

    public var errorDescription: String? {
        switch self {
        case .unknownBackend(let name):
            return "Unknown summarization backend: '\(name)'. Use 'openai', 'anthropic', or 'ollama'."
        case .missingAPIKey(let backend, let envVar):
            return "No \(backend) API key found (Keychain or \(envVar) env var)."
        }
    }
}
