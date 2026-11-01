import Foundation

struct ModelsDevSnapshot: Sendable {
    var pricing: [String: ChatModelPricing] = [:]
    var summaryModels: [LLMBackend: [String]] = [:]
    var geminiTranscriptionModels: [String]?

    init() {}

    init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.invalidPayload
        }
        // Read direct vendor prices last so reseller entries cannot replace them.
        let direct = ["openai", "anthropic", "google", "google-vertex"]
        for providerID in root.keys.filter({ !direct.contains($0) }).sorted() + direct {
            guard let provider = root[providerID] as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            readPricing(models)
            switch providerID {
            case "openai": summaryModels[.openai] = modelIDs(models, prefix: "", audio: false)
            case "anthropic": summaryModels[.anthropic] = modelIDs(models, prefix: "claude-", audio: false)
            case "google-vertex": summaryModels[.gemini] = modelIDs(models, prefix: "gemini-", audio: false)
            case "google": geminiTranscriptionModels = modelIDs(models, prefix: "gemini-", audio: true)
            default: break
            }
        }
        guard !summaryModels.isEmpty else { throw CatalogError.invalidPayload }
    }

    private func modelIDs(_ models: [String: Any], prefix: String, audio: Bool) -> [String] {
        models.compactMap { id, value -> (id: String, released: String)? in
            guard id.hasPrefix(prefix), let model = value as? [String: Any],
                  model["status"] as? String != "deprecated",
                  let modalities = model["modalities"] as? [String: Any],
                  let inputs = modalities["input"] as? [String],
                  let outputs = modalities["output"] as? [String],
                  outputs == ["text"], inputs.contains(audio ? "audio" : "text"),
                  !requiresAnotherAPI(id: id, model: model) else { return nil }
            return (id, model["release_date"] as? String ?? "")
        }
        .sorted { lhs, rhs in
            lhs.released == rhs.released ? lhs.id < rhs.id : lhs.released > rhs.released
        }
        .map(\.id)
    }

    private func requiresAnotherAPI(id: String, model: [String: Any]) -> Bool {
        // models.dev has no endpoint field; omit families that need another API or special access.
        let unsupported = ["embedding", "codex", "deep-research", "computer-use", "daybreak", "realtime", "transcribe"]
        let family = model["family"] as? String ?? ""
        return unsupported.contains { id.contains($0) || family.contains($0) }
            || id.hasSuffix("-pro") && !id.hasPrefix("gemini-")
    }

    private mutating func readPricing(_ models: [String: Any]) {
        for (id, value) in models {
            guard let model = value as? [String: Any],
                  let cost = model["cost"] as? [String: Any],
                  let input = numericValue(cost["input"]),
                  let output = numericValue(cost["output"]) else { continue }
            pricing[id] = ChatModelPricing(inputPerMillion: input, outputPerMillion: output)
        }
    }

    private func numericValue(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let string = raw as? String { return Double(string) }
        return nil
    }

    private enum CatalogError: Error { case invalidPayload }
}
