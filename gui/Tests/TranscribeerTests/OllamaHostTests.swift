import Foundation
import LLM
import Testing
@testable import TranscribeerApp

struct OllamaHostTests {
    @Test("Base URL drops a trailing slash and /v1",
          arguments: [
              "http://localhost:11434",
              "http://localhost:11434/",
              "http://localhost:11434/v1",
              "http://localhost:11434/V1/",
              " http://localhost:11434 ",
          ])
    func normalizes(host: String) {
        #expect(OllamaHost.baseURL(host)?.absoluteString == "http://localhost:11434")
    }

    @Test("A host without scheme or host part is invalid",
          arguments: ["", "localhost:11434", "not a url"])
    func rejectsInvalid(host: String) {
        #expect(OllamaHost.baseURL(host) == nil)
    }

    /// Builds the request URL the same way the LLM package does, so a change in
    /// how the package joins its endpoint makes this test fail.
    @Test("The Ollama provider sends chat requests to /v1/chat/completions once",
          arguments: ["http://localhost:11434", "http://localhost:11434/v1"])
    func providerChatURL(host: String) async throws {
        let (provider, _) = try SummarizationService.resolveProvider(.ollama, model: "gemma4", ollamaHost: host)
        let api = await LLM(provider: provider).providerApi
        let url = api.baseURL.appending(path: api.chatEndpoint)
        #expect(url.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    @Test("An invalid host throws invalidOllamaHost with the value the user typed")
    func providerRejectsInvalidHost() {
        #expect {
            try SummarizationService.resolveProvider(.ollama, model: "gemma4", ollamaHost: "localhost:11434")
        } throws: { error in
            guard case let SummarizationError.invalidOllamaHost(value) = error else { return false }
            return value == "localhost:11434"
        }
    }
}
