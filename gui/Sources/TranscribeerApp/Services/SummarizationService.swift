import Foundation
import LLM

/// Summarizes transcripts via OpenAI, Anthropic, Gemini (Vertex AI), or Ollama.
enum SummarizationService {
    static let defaultPrompt = """
        You are a meeting summarizer. Given a meeting transcript with speaker \
        labels and timestamps, produce a concise summary in the same language \
        as the transcript. Include:
        - 2-3 sentence overview
        - Key decisions made
        - Action items (who, what)
        - Open questions

        Respond in markdown.
        """

    /// Stream a summary as incremental text deltas. Consumers should concatenate
    /// the yielded fragments for the running total. The stream finishes when
    /// the model is done; no `.completed` sentinel is emitted.
    ///
    /// `LLM` is an actor, so its `streamConversation` factory is implicitly
    /// async — hence this method is async even though the heavy lifting
    /// happens inside the returned stream.
    ///
    /// - Parameters:
    ///   - transcript: Full transcript text.
    ///   - backend: One of `LLMBackend` — openai, anthropic, gemini, ollama.
    ///   - model: Model name (e.g. "gpt-4o", "claude-sonnet-4-20250514", "gemini-2.0-flash").
    ///   - ollamaHost: Ollama base URL (default: localhost:11434).
    ///   - prompt: Custom system prompt, or nil for default.
    static func streamSummarize(
        transcript: String,
        backend: String,
        model: String,
        ollamaHost: String = "http://localhost:11434",
        prompt: String? = nil,
    ) async throws -> AsyncThrowingStream<String, Error> {
        guard let kind = LLMBackend(rawValue: backend) else {
            throw SummarizationError.unknownBackend(backend)
        }
        let (provider, resolvedModel) = try resolveProvider(kind, model: model, ollamaHost: ollamaHost)

        let llm = LLM(provider: provider)
        let config = LLM.ConversationConfiguration(
            modelType: .fast,
            inference: .direct,
            model: .init(rawValue: resolvedModel)
        )
        let source = await llm.streamConversation(
            systemPrompt: prompt ?? defaultPrompt,
            userMessage: transcript,
            configuration: config,
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in source {
                        if case let .textDelta(fragment) = event, !fragment.isEmpty {
                            continuation.yield(fragment)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Load a prompt profile from ~/.transcribeer/prompts/<name>.md.
    /// Returns nil if the file doesn't exist or name is nil/"default".
    static func loadPromptProfile(_ name: String?) -> String? {
        guard let name, name != "default" else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/prompts/\(name).md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Private

    /// Build the LLM provider + model id for the given backend.
    ///
    /// Returns the resolved model because Vertex AI requires a `google/` prefix
    /// that callers shouldn't have to remember.
    private static func resolveProvider(
        _ backend: LLMBackend,
        model: String,
        ollamaHost: String,
    ) throws -> (LLM.Provider, String) {
        switch backend {
        case .openai:
            return (.openAI(apiKey: try requireAPIKey(for: backend)), model)
        case .anthropic:
            return (.anthropic(apiKey: try requireAPIKey(for: backend)), model)
        case .gemini:
            // Vertex AI's OpenAI-compatible endpoint authenticates via the
            // user's gcloud ADC, so no API key is stored or typed in-app.
            let project = try GCloudAuth.project()
            let region = GCloudAuth.defaultRegion
            let url = try requireURL(
                "https://\(region)-aiplatform.googleapis.com/v1beta1" +
                "/projects/\(project)/locations/\(region)/endpoints/openapi"
            )
            let resolvedModel = model.hasPrefix("google/") ? model : "google/\(model)"
            return (.other(url, apiKey: try GCloudAuth.accessToken()), resolvedModel)
        case .ollama:
            return (.other(try requireURL("\(ollamaHost)/v1"), apiKey: nil), model)
        }
    }

    private static func requireURL(_ string: String) throws -> URL {
        guard let url = URL(string: string) else {
            throw SummarizationError.invalidOllamaHost(string)
        }
        return url
    }

    private static func requireAPIKey(for backend: LLMBackend) throws -> String {
        if let key = KeychainHelper.getAPIKey(backend: backend.rawValue), !key.isEmpty {
            return key
        }
        if let envVar = backend.envVar,
           let key = ProcessInfo.processInfo.environment[envVar], !key.isEmpty {
            return key
        }
        throw SummarizationError.missingAPIKey(backend.rawValue, backend.envVar ?? "")
    }
}

enum SummarizationError: LocalizedError {
    case unknownBackend(String)
    case missingAPIKey(String, String)
    case invalidOllamaHost(String)

    var errorDescription: String? {
        switch self {
        case let .unknownBackend(name):
            let supported = LLMBackend.allCases.map(\.rawValue).joined(separator: ", ")
            return "Unknown summarization backend: '\(name)'. Supported: \(supported)."
        case let .missingAPIKey(backend, envVar):
            return "No \(backend) API key found (Keychain or \(envVar) env var)."
        case let .invalidOllamaHost(value):
            return "Invalid Ollama host URL: '\(value)'."
        }
    }
}
