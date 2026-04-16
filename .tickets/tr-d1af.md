{
  "id": "tr-d1af",
  "title": "Add bensyverson/LLM dependency + SummarizationService",
  "status": "closed",
  "type": "feature",
  "priority": 2,
  "tests_passed": true,
  "created_at": "2026-04-16T14:47:01.037Z",
  "parent": "tr-ab5f"
}

Add bensyverson/LLM as SPM dependency and create SummarizationService.swift.

SPM: `.package(url: "https://github.com/bensyverson/LLM.git", branch: "main")`

Provider mapping:
- Ollama → LLM with custom baseURL (ollamaHost + "/v1"), Ollama's OpenAI-compatible endpoint
- OpenAI → LLM with .openAI provider
- Anthropic → LLM with .anthropic provider

Read API keys from KeychainHelper or environment.
Port SYSTEM_PROMPT from Python summarize.py.
Port prompt profile loading from ~/.transcribeer/prompts/.

## Design

```swift
enum SummarizationService {
    static let defaultPrompt = """
    You are a meeting summarizer. Given a meeting transcript...
    """
    
    static func summarize(
        transcript: String,
        backend: String,
        model: String,
        ollamaHost: String,
        prompt: String?
    ) async throws -> String
    
    static func loadPromptProfile(_ name: String?) -> String?
}
```

## Acceptance Criteria

- Ollama summarization works (localhost)
- OpenAI summarization works with API key from Keychain
- Anthropic summarization works with API key from Keychain
- Custom prompt profiles from ~/.transcribeer/prompts/ loaded correctly
- Errors surfaced with descriptive messages (missing API key, connection refused, etc.)

## Tests

- Test prompt profile loading from disk
- Test default prompt used when no profile specified
- Test error message when API key missing
