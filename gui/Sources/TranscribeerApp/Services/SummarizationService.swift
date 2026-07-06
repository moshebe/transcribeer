import Foundation
import LLM

/// Token counts reported alongside a streaming summary's final event.
struct TokenUsage: Equatable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
}

/// Events yielded by `SummarizationService.streamSummarize`. Text fragments
/// arrive as `.textDelta`; the stream finishes with a single `.completed`
/// carrying token usage when the provider reported it (some Ollama models
/// don't, so it's optional).
enum SummarizationStreamEvent: Sendable {
    case textDelta(String)
    case completed(usage: TokenUsage?)
}

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

    /// System prompt for the one-sentence sidebar description. Kept short and
    /// strict on format because the output is shown verbatim in the history
    /// sidebar — markdown, quotes, or multi-line replies would look broken.
    static let descriptionPrompt = """
        Summarize the following meeting summary in exactly one sentence.
        Reply with that single sentence and nothing else: no markdown, no \
        headings, no bullets, no quotes, no prefixes like "Summary:". Use the \
        same language as the input. Aim for 8\u{2013}20 words. Describe what \
        the meeting was about and, if clear, its outcome.
        """

    /// Stream a summary as incremental events. Text fragments arrive as
    /// `.textDelta`; the stream ends with a `.completed` carrying token usage
    /// when the provider reported it. Consumers concatenate the `.textDelta`
    /// fragments for the running total.
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
    ) async throws -> AsyncThrowingStream<SummarizationStreamEvent, Error> {
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
                        switch event {
                        case let .textDelta(fragment) where !fragment.isEmpty:
                            continuation.yield(.textDelta(fragment))
                        case let .completed(response):
                            continuation.yield(.completed(usage: tokenUsage(from: response)))
                        default:
                            break
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

    /// Extract `TokenUsage` from an LLM `ConversationResponse`, handling both
    /// the OpenAI (`prompt_tokens`/`completion_tokens`) and Anthropic
    /// (`input_tokens`/`output_tokens`) shapes. Returns `nil` when the
    /// provider didn't report usage (some Ollama builds).
    private static func tokenUsage(from response: LLM.ConversationResponse) -> TokenUsage? {
        let usage = response.rawResponse.usage
        guard let input = usage.prompt_tokens ?? usage.input_tokens,
              let output = usage.completion_tokens ?? usage.output_tokens
        else { return nil }
        return TokenUsage(inputTokens: input, outputTokens: output)
    }

    /// Load a prompt profile from ~/.transcribeer/prompts/<name>.md.
    /// Returns nil if the file doesn't exist (caller falls back to the built-in
    /// `defaultPrompt`). For `default`, an on-disk file is treated as a user
    /// override of the built-in prompt.
    static func loadPromptProfile(_ name: String?) -> String? {
        guard let name else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/prompts/\(name).md")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Generate a single-sentence description of a meeting from its summary.
    ///
    /// Runs as a small follow-up call after the main summary so it can see the
    /// same content the user sees. Reuses `streamSummarize` with the strict
    /// `descriptionPrompt` and collapses the reply to one clean sentence.
    static func generateDescription(
        summary: String,
        backend: String,
        model: String,
        ollamaHost: String = "http://localhost:11434",
    ) async throws -> String {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let stream = try await streamSummarize(
            transcript: trimmed,
            backend: backend,
            model: model,
            ollamaHost: ollamaHost,
            prompt: descriptionPrompt,
        )
        var accumulated = ""
        for try await event in stream {
            try Task.checkCancellation()
            if case let .textDelta(fragment) = event {
                accumulated += fragment
            }
        }
        return sanitizeOneSentence(accumulated)
    }

    /// Collapse a model reply to a single clean sentence: strip outer quotes,
    /// markdown markers, leading bullets / headings, and join wrapped lines
    /// with a single space. Exposed `internal` so tests can pin the behaviour
    /// without going through the LLM.
    static func sanitizeOneSentence(_ raw: String) -> String {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let joined = lines.joined(separator: " ")
        let stripChars = CharacterSet(charactersIn: "\"'`*_ \t")
        var result = joined.trimmingCharacters(in: stripChars)
        // Drop a leading markdown heading marker (e.g. `# `, `## `) or bullet.
        while let first = result.first, "#-*>".contains(first) {
            result.removeFirst()
            result = result.trimmingCharacters(in: stripChars)
        }
        // Drop a leading label like "Summary:" / "Description:" the model
        // sometimes adds despite the prompt.
        if let colon = result.firstIndex(of: ":"),
           result.distance(from: result.startIndex, to: colon) <= 20,
           result[..<colon].allSatisfy({ $0.isLetter || $0.isWhitespace }) {
            result = String(result[result.index(after: colon)...])
                .trimmingCharacters(in: stripChars)
        }
        return result.trimmingCharacters(in: stripChars)
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
