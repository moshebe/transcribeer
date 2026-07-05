import Foundation

/// Token / cost / model metadata captured after a transcription or summary
/// completes. Persisted into `meta.json` so the detail view can show what
/// each artifact cost without re-running anything.
struct PipelineUsage: Equatable, Sendable {
    /// Provider tag — e.g. `openai`, `anthropic`, `gemini`, `ollama`,
    /// `whisperkit`. Stored verbatim so we don't have to migrate when new
    /// backends are added.
    let backend: String
    /// Model id as the user/picker chose it (`gpt-4o`, `large-v3`, …).
    let model: String
    /// Prompt / input tokens for LLM calls. `nil` for transcription.
    let inputTokens: Int?
    /// Completion / output tokens for LLM calls. `nil` for transcription.
    let outputTokens: Int?
    /// Total audio processed, in seconds. Set for transcription so cost is
    /// rederivable from the price-per-minute catalog. `nil` for summaries.
    let audioSeconds: Double?
    /// Estimated cost in USD. `nil` when the model isn't in
    /// `PricingCatalog` — the rest of the badges still render.
    let costUSD: Double?
    /// Wall-clock seconds spent generating this artifact. Useful both as a
    /// debugging signal and as a "how long did the LLM take" badge.
    let durationSeconds: Double
    /// When the artifact finished. ISO-8601 in storage.
    let completedAt: Date

    /// `inputTokens + outputTokens`, or `nil` if either is missing.
    var totalTokens: Int? {
        guard let inputTokens, let outputTokens else { return nil }
        return inputTokens + outputTokens
    }
}

extension PipelineUsage {
    /// Decode from the JSON dict shape persisted in `meta.json`.
    init?(dict: [String: Any]) {
        guard let backend = dict["backend"] as? String,
              let model = dict["model"] as? String,
              let completedAtString = dict["completed_at"] as? String,
              let completedAt = SessionManager.isoFormatter.date(from: completedAtString)
        else { return nil }
        self.backend = backend
        self.model = model
        self.inputTokens = dict["input_tokens"] as? Int
        self.outputTokens = dict["output_tokens"] as? Int
        self.audioSeconds = (dict["audio_seconds"] as? NSNumber)?.doubleValue
        self.costUSD = (dict["cost_usd"] as? NSNumber)?.doubleValue
        self.durationSeconds = (dict["duration_seconds"] as? NSNumber)?.doubleValue ?? 0
        self.completedAt = completedAt
    }

    /// Encode to the JSON dict shape persisted in `meta.json`. Optional
    /// fields are omitted rather than written as `null` so legacy readers
    /// (and `jq`) see a tight document.
    func dict() -> [String: Any] {
        var out: [String: Any] = [
            "backend": backend,
            "model": model,
            "duration_seconds": durationSeconds,
            "completed_at": SessionManager.isoFormatter.string(from: completedAt),
        ]
        if let inputTokens { out["input_tokens"] = inputTokens }
        if let outputTokens { out["output_tokens"] = outputTokens }
        if let audioSeconds { out["audio_seconds"] = audioSeconds }
        if let costUSD { out["cost_usd"] = costUSD }
        return out
    }
}
