import Foundation
import Testing
@testable import TranscribeerApp

struct TranscriptionBackendTests {
    @Test("Raw values match config.toml strings")
    func rawValues() {
        #expect(TranscriptionBackend.whisperkit.rawValue == "whisperkit")
        #expect(TranscriptionBackend.openai.rawValue == "openai")
        #expect(TranscriptionBackend.gemini.rawValue == "gemini")
    }

    @Test("Only cloud backends use API keys")
    func usesAPIKey() {
        #expect(TranscriptionBackend.whisperkit.usesAPIKey == false)
        #expect(TranscriptionBackend.openai.usesAPIKey == true)
        #expect(TranscriptionBackend.gemini.usesAPIKey == true)
    }

    @Test("Keychain slots: openai shares with summarization, gemini gets its own")
    func keychainSlots() {
        // Sharing the openai slot is intentional — users only configure their
        // OpenAI key once, both transcription and summarization read it.
        #expect(TranscriptionBackend.openai.keychainKey == LLMBackend.openai.rawValue)
        // gemini uses its own slot since the LLM side authenticates via gcloud ADC.
        #expect(TranscriptionBackend.gemini.keychainKey == "gemini")
        #expect(TranscriptionBackend.whisperkit.keychainKey.isEmpty)
    }

    @Test("Env var fallbacks line up with the cloud APIs")
    func envVars() {
        #expect(TranscriptionBackend.whisperkit.envVar == nil)
        #expect(TranscriptionBackend.openai.envVar == "OPENAI_API_KEY")
        #expect(TranscriptionBackend.gemini.envVar == "GEMINI_API_KEY")
    }

    @Test("from(_:) falls back to whisperkit for unknown values")
    func fromFallback() {
        #expect(TranscriptionBackend.from("whisperkit") == .whisperkit)
        #expect(TranscriptionBackend.from("openai") == .openai)
        #expect(TranscriptionBackend.from("gemini") == .gemini)
        #expect(TranscriptionBackend.from("not-a-backend") == .whisperkit)
        #expect(TranscriptionBackend.from("") == .whisperkit)
    }

    @Test("Defaults are documented contract for the Settings picker")
    func defaultModels() {
        // whisper-1 returns segment timestamps via verbose_json. Changing this
        // default would silently degrade dual-source interleave quality.
        #expect(TranscriptionBackend.openai.defaultModel == "whisper-1")
        // gemini-2.5-flash accepts audio + supports JSON-mode output.
        #expect(TranscriptionBackend.gemini.defaultModel == "gemini-2.5-flash")
    }

    @Test("allCases covers every backend (prevents picker regressions)")
    func allCasesCoverage() {
        let cases = Set(TranscriptionBackend.allCases.map(\.rawValue))
        #expect(cases == ["whisperkit", "openai", "gemini"])
    }
}
