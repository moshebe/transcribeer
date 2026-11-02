import Foundation

/// A concrete (backend, model) pair that the user can pick from the summary
/// tab's model selector. Identity is the composite so SwiftUI can diff rows
/// across backends without colliding on plain model names.
struct SummaryModelOption: Hashable, Identifiable, Sendable {
    let backend: LLMBackend
    let model: String

    var id: String { "\(backend.rawValue)/\(model)" }

    /// Short label for menu rows, e.g. `gpt-4o` (backend shown in the section
    /// header, not per-row, to keep the menu compact).
    var shortLabel: String { model }
}

/// Model menus use models.dev, with a bundled fallback for the first offline launch.
/// Ollama is fetched live via `/api/tags` because local installs vary wildly.
enum SummarizationCatalog {
    /// Commonly-used OpenAI models for summarization.
    static let openaiModels = [
        "gpt-6.1-sol",
        "gpt-6.1-terra",
        "gpt-6-luna",
        "gpt-6-astra",
    ]

    /// Commonly-used Anthropic models.
    static let anthropicModels = [
        "claude-sonnet-5-5",
        "claude-haiku-5-5",
        "claude-opus-5-5",
    ]

    /// Commonly-used Gemini (Vertex) models.
    static let geminiModels = [
        "gemini-3.8-flash",
        "gemini-4-argon",
        "gemini-2.5-flash",
        "gemini-2.5-pro",
    ]

    @MainActor
    static func models(for backend: LLMBackend, ollamaModels: [String] = []) -> [String] {
        if let live = ModelsDevService.shared.summaryModels(for: backend) { return live }
        return bundledModels(for: backend, ollamaModels: ollamaModels)
    }

    static func defaultModel(for backend: LLMBackend, availableModels: [String]) -> String {
        let preferred = bundledModels(for: backend, ollamaModels: availableModels)
        return preferred.first(where: availableModels.contains) ?? preferred.first ?? AppConfig().llmModel
    }

    private static func bundledModels(for backend: LLMBackend, ollamaModels: [String]) -> [String] {
        switch backend {
        case .openai: openaiModels
        case .anthropic: anthropicModels
        case .gemini: geminiModels
        case .ollama: ollamaModels
        }
    }

    @MainActor
    static var cloudOptions: [SummaryModelOption] {
        LLMBackend.allCases.flatMap { backend in
            models(for: backend).map { SummaryModelOption(backend: backend, model: $0) }
        }
    }

    @MainActor
    static var geminiTranscriptionModels: [String] {
        ModelsDevService.shared.geminiTranscriptionModels ?? geminiModels
    }

    /// Curated cloud catalog (Ollama is fetched live).
    static let staticOptions: [SummaryModelOption] =
        openaiModels.map { SummaryModelOption(backend: .openai, model: $0) }
            + anthropicModels.map { SummaryModelOption(backend: .anthropic, model: $0) }
            + geminiModels.map { SummaryModelOption(backend: .gemini, model: $0) }

    /// Merge the user's current default (from config) into a list of options,
    /// preserving order and deduping. Guarantees the default is always present
    /// so the collapsed picker renders it correctly even if it's a custom name.
    static func optionsIncludingDefault(
        default defaultOption: SummaryModelOption,
        ollamaModels: [String],
        staticModels: [SummaryModelOption] = staticOptions,
    ) -> [SummaryModelOption] {
        var seen: Set<String> = []
        var out: [SummaryModelOption] = []

        func add(_ option: SummaryModelOption) {
            guard seen.insert(option.id).inserted else { return }
            out.append(option)
        }

        add(defaultOption)
        ollamaModels.forEach { add(SummaryModelOption(backend: .ollama, model: $0)) }
        staticModels.forEach(add)
        return out
    }

    /// Query the given Ollama host for locally-pulled models.
    ///
    /// Returns an empty array on any failure — the picker falls back to the
    /// default option, so a missing Ollama daemon doesn't block the UI.
    static func fetchOllamaModels(host: String) async -> [String] {
        guard let base = URL(string: host) else { return [] }
        var request = URLRequest(url: base.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else { return [] }
            return parseTags(data)
        } catch {
            return []
        }
    }

    private static func parseTags(_ data: Data) -> [String] {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = json["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
    }
}
