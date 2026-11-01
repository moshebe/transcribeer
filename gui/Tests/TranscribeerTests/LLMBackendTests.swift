import Foundation
import Testing
@testable import TranscribeerApp

struct LLMBackendTests {
    @Test("Raw values match config.toml strings")
    func rawValues() {
        #expect(LLMBackend.ollama.rawValue == "ollama")
        #expect(LLMBackend.openai.rawValue == "openai")
        #expect(LLMBackend.anthropic.rawValue == "anthropic")
        #expect(LLMBackend.gemini.rawValue == "gemini")
    }

    @Test("env vars match the ones SummarizationService reads")
    func envVars() {
        #expect(LLMBackend.openai.envVar == "OPENAI_API_KEY")
        #expect(LLMBackend.anthropic.envVar == "ANTHROPIC_API_KEY")
        #expect(LLMBackend.gemini.envVar == nil)
        #expect(LLMBackend.ollama.envVar == nil)
    }

    @Test("from(_:) falls back to ollama for unknown values")
    func fromUnknown() {
        #expect(LLMBackend.from("openai") == .openai)
        #expect(LLMBackend.from("not-a-backend") == .ollama)
        #expect(LLMBackend.from("") == .ollama)
    }
}
