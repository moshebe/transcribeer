import Foundation
import Testing
@testable import TranscribeerApp

struct OllamaBaseURLTests {
    @Test("Ollama base URL has no /v1, so the chat endpoint is not doubled",
          arguments: [
              "http://localhost:11434",
              "http://localhost:11434/",
              "http://localhost:11434/v1",
              "http://localhost:11434/v1/",
              " http://localhost:11434 ",
          ])
    func stripsVersionSuffix(host: String) throws {
        let url = try SummarizationService.ollamaBaseURL(host)
        #expect(url.absoluteString == "http://localhost:11434")
        #expect(
            url.appending(path: "v1/chat/completions").absoluteString
                == "http://localhost:11434/v1/chat/completions"
        )
    }
}
