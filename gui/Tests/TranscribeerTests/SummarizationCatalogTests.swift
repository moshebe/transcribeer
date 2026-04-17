import Foundation
import Testing
@testable import TranscribeerApp

struct SummarizationCatalogTests {
    @Test("Default option is always present and comes first")
    func defaultFirst() {
        let defaultModel = SummaryModelOption(backend: .openai, model: "gpt-4o")
        let options = SummarizationCatalog.optionsIncludingDefault(
            default: defaultModel,
            ollamaModels: [],
        )
        #expect(options.first == defaultModel)
        #expect(options.contains(defaultModel))
    }

    @Test("Custom default that isn't in the static list is preserved")
    func customDefaultPreserved() {
        let custom = SummaryModelOption(backend: .ollama, model: "custom-finetune:latest")
        let options = SummarizationCatalog.optionsIncludingDefault(
            default: custom,
            ollamaModels: [],
        )
        #expect(options.contains(custom))
    }

    @Test("Ollama tags from the local daemon appear as options")
    func ollamaTagsIncluded() {
        let defaultModel = SummaryModelOption(backend: .openai, model: "gpt-4o")
        let options = SummarizationCatalog.optionsIncludingDefault(
            default: defaultModel,
            ollamaModels: ["llama3:latest", "mistral:7b"],
        )
        let ids = options.map(\.id)
        #expect(ids.contains("ollama/llama3:latest"))
        #expect(ids.contains("ollama/mistral:7b"))
    }

    @Test("Duplicate ids are dropped")
    func dedupe() {
        let defaultModel = SummaryModelOption(backend: .ollama, model: "llama3:latest")
        let options = SummarizationCatalog.optionsIncludingDefault(
            default: defaultModel,
            ollamaModels: ["llama3:latest", "llama3:latest"],
        )
        let count = options.count { $0.id == "ollama/llama3:latest" }
        #expect(count == 1)
    }
}

@MainActor
struct PromptCompositionTests {
    @Test("No focus text returns the base prompt unchanged")
    func noFocusPassesBaseThrough() {
        let base = "custom profile prompt"
        #expect(PipelineRunner.composePrompt(base: base, focus: nil) == base)
        #expect(PipelineRunner.composePrompt(base: base, focus: "") == base)
        #expect(PipelineRunner.composePrompt(base: base, focus: "   \n  ") == base)
    }

    @Test("Focus text is appended to the base prompt")
    func focusAppendedToBase() throws {
        let result = PipelineRunner.composePrompt(base: "base", focus: "focus on Q3 roadmap")
        let composed = try #require(result)
        #expect(composed.contains("base"))
        #expect(composed.contains("focus on Q3 roadmap"))
        #expect(composed.contains("Additional instructions"))
    }

    @Test("Focus without base prompt falls back to the default summarizer prompt")
    func focusUsesDefaultWhenBaseIsNil() throws {
        let result = PipelineRunner.composePrompt(base: nil, focus: "key decisions only")
        let composed = try #require(result)
        #expect(composed.contains(SummarizationService.defaultPrompt))
        #expect(composed.contains("key decisions only"))
    }

    @Test("Nil base and empty focus returns nil (service falls back to default)")
    func nothingToDo() {
        #expect(PipelineRunner.composePrompt(base: nil, focus: nil) == nil)
        #expect(PipelineRunner.composePrompt(base: nil, focus: "") == nil)
    }
}
