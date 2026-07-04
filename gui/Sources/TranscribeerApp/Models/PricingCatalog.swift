import Foundation

/// Estimates per-session USD cost from token counts (summarization) and
/// audio duration (cloud transcription).
///
/// Chat pricing comes from `ModelPricingService` (which fetches
/// <https://models.dev/api.json> in the background and caches it on disk).
/// When the catalog hasn't been populated yet — first launch, offline, etc.
/// — we fall back to a tiny hardcoded table covering the models in the
/// in-app picker so the badge isn't empty on day one.
///
/// Audio transcription stays hardcoded: per-minute pricing isn't published
/// by models.dev and the relevant set (Whisper, gpt-4o-transcribe, Gemini
/// audio) is small.
@MainActor
enum PricingCatalog {
    /// USD per **minute of audio** for speech-to-text models.
    struct AudioModelPricing: Sendable {
        let perMinute: Double
    }

    /// Last-resort chat pricing. Kept short — `ModelPricingService` is the
    /// source of truth once the catalog cache has been hydrated.
    static let fallbackChatModels: [String: ChatModelPricing] = [
        "gpt-5": .init(inputPerMillion: 1.25, outputPerMillion: 10.0),
        "gpt-5-mini": .init(inputPerMillion: 0.25, outputPerMillion: 2.0),
        "gpt-4o": .init(inputPerMillion: 2.5, outputPerMillion: 10.0),
        "gpt-4o-mini": .init(inputPerMillion: 0.15, outputPerMillion: 0.6),
        "claude-sonnet-4-5": .init(inputPerMillion: 3.0, outputPerMillion: 15.0),
        "claude-3-5-haiku-latest": .init(inputPerMillion: 0.8, outputPerMillion: 4.0),
        "gemini-2.5-pro": .init(inputPerMillion: 1.25, outputPerMillion: 10.0),
        "gemini-2.5-flash": .init(inputPerMillion: 0.3, outputPerMillion: 2.5),
    ]

    static let audioModels: [String: AudioModelPricing] = [
        "whisper-1": .init(perMinute: 0.006),
        "gpt-4o-transcribe": .init(perMinute: 0.006),
        "gpt-4o-mini-transcribe": .init(perMinute: 0.003),
        "gemini-2.5-flash": .init(perMinute: 0.001),
        "gemini-2.0-flash": .init(perMinute: 0.001),
    ]

    /// Estimated USD cost for a summarization call. Returns `nil` when the
    /// model isn't in the catalog or token counts are missing; `0` for
    /// local backends (`ollama`).
    static func summarizationCost(
        backend: String,
        model: String,
        inputTokens: Int?,
        outputTokens: Int?,
    ) -> Double? {
        if backend == LLMBackend.ollama.rawValue { return 0 }
        guard let pricing = chatPricing(for: model),
              let inputTokens,
              let outputTokens
        else { return nil }
        let input = Double(inputTokens) * pricing.inputPerMillion / 1_000_000
        let output = Double(outputTokens) * pricing.outputPerMillion / 1_000_000
        return input + output
    }

    /// Estimated USD cost for a transcription. Returns `nil` when the model
    /// isn't in the catalog. Local `whisperkit` is free → `0`.
    static func transcriptionCost(
        backend: String,
        model: String,
        audioSeconds: Double?,
    ) -> Double? {
        if backend == TranscriptionBackend.whisperkit.rawValue { return 0 }
        guard let pricing = audioModels[model], let audioSeconds else { return nil }
        return pricing.perMinute * audioSeconds / 60
    }

    /// Look up chat pricing, preferring the live `ModelPricingService`
    /// snapshot and falling back to the bundled table. Also strips trailing
    /// version dates (`gpt-4o-2024-05-13` → `gpt-4o`) so dated snapshots map
    /// onto their base model.
    private static func chatPricing(for model: String) -> ChatModelPricing? {
        if let live = ModelPricingService.shared.chatPricing(for: model) { return live }
        if let exact = fallbackChatModels[model] { return exact }
        let lowered = model.lowercased()
        if let lowercaseHit = fallbackChatModels[lowered] { return lowercaseHit }
        let trimmed = lowered.split(separator: "-").dropLast(3).joined(separator: "-")
        if !trimmed.isEmpty, let hit = fallbackChatModels[trimmed] {
            return hit
        }
        return nil
    }
}
