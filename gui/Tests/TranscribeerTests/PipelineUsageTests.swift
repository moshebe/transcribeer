import Foundation
import Testing
@testable import TranscribeerApp

/// Round-trip + cost-math invariants for the per-session `PipelineUsage`
/// record. The struct is written verbatim into `meta.json`, so the
/// dict-encoding shape matters for forward compatibility with older sessions.
@Suite("PipelineUsage")
struct PipelineUsageTests {
    @Test("summary metadata round-trips through the dict shape")
    func roundTripsSummary() throws {
        // The shared formatter requires `.withFractionalSeconds`, so the
        // fixture must include them — otherwise `.date(from:)` returns nil
        // and we'd silently round-trip a sub-millisecond `Date()` that the
        // millisecond-precision formatter can't reproduce exactly.
        let completedAt = try #require(
            SessionManager.isoFormatter.date(from: "2026-05-12T08:30:00.000Z"),
        )
        let original = PipelineUsage(
            backend: "openai",
            model: "gpt-4o",
            inputTokens: 12_345,
            outputTokens: 678,
            audioSeconds: nil,
            costUSD: 0.0345,
            durationSeconds: 12.4,
            completedAt: completedAt,
        )
        let decoded = try #require(PipelineUsage(dict: original.dict()))
        #expect(decoded == original)
    }

    @Test("transcription metadata round-trips and omits token fields")
    func roundTripsTranscription() throws {
        let completedAt = try #require(
            SessionManager.isoFormatter.date(from: "2026-05-12T08:30:00.000Z"),
        )
        let original = PipelineUsage(
            backend: "whisperkit",
            model: "openai_whisper-large-v3_turbo",
            inputTokens: nil,
            outputTokens: nil,
            audioSeconds: 1_234,
            costUSD: 0,
            durationSeconds: 92.4,
            completedAt: completedAt,
        )
        let dict = original.dict()
        #expect(dict["input_tokens"] == nil, "token fields should be elided when nil")
        #expect(dict["output_tokens"] == nil)
        #expect(PipelineUsage(dict: dict) == original)
    }

    @Test("totalTokens is nil when either side is missing")
    func totalTokensRequiresBothSides() {
        let onlyInput = PipelineUsage.fixture(inputTokens: 100, outputTokens: nil)
        #expect(onlyInput.totalTokens == nil)
        let both = PipelineUsage.fixture(inputTokens: 100, outputTokens: 50)
        #expect(both.totalTokens == 150)
    }

    @Test("decoder rejects payloads missing required fields")
    func rejectsMalformedPayloads() {
        let missingModel: [String: Any] = [
            "backend": "openai",
            "completed_at": "2026-05-12T08:30:00Z",
        ]
        #expect(PipelineUsage(dict: missingModel) == nil)
    }
}

@Suite("PricingCatalog")
@MainActor
struct PricingCatalogTests {
    @Test("ollama summaries are free")
    func ollamaIsFree() {
        let cost = PricingCatalog.summarizationCost(
            backend: "ollama",
            model: "llama3:70b",
            inputTokens: 10_000,
            outputTokens: 5_000,
        )
        #expect(cost == 0)
    }

    @Test("known OpenAI model produces a positive cost")
    func openaiCostFromFallback() throws {
        let cost = try #require(PricingCatalog.summarizationCost(
            backend: "openai",
            model: "gpt-4o-mini",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
        ))
        // gpt-4o-mini: $0.15 in + $0.60 out per 1M = $0.75
        #expect(abs(cost - 0.75) < 0.0001)
    }

    @Test("missing token counts collapse cost to nil")
    func missingTokensProducesNil() {
        let cost = PricingCatalog.summarizationCost(
            backend: "openai",
            model: "gpt-4o",
            inputTokens: nil,
            outputTokens: 500,
        )
        #expect(cost == nil)
    }

    @Test("local whisperkit transcription is free")
    func whisperkitFree() {
        let cost = PricingCatalog.transcriptionCost(
            backend: "whisperkit",
            model: "large-v3",
            audioSeconds: 600,
        )
        #expect(cost == 0)
    }

    @Test("openai whisper-1 priced per audio minute")
    func whisperPerMinute() throws {
        // 600s = 10 minutes; whisper-1 is $0.006/min ⇒ $0.06.
        let cost = try #require(PricingCatalog.transcriptionCost(
            backend: "openai",
            model: "whisper-1",
            audioSeconds: 600,
        ))
        #expect(abs(cost - 0.06) < 0.0001)
    }

    @Test("unknown cloud model is reported as nil so the badge hides")
    func unknownModelHasNilCost() {
        let cost = PricingCatalog.transcriptionCost(
            backend: "openai",
            model: "made-up-future-model",
            audioSeconds: 300,
        )
        #expect(cost == nil)
    }
}

private extension PipelineUsage {
    static func fixture(
        inputTokens: Int? = 1,
        outputTokens: Int? = 1,
    ) -> PipelineUsage {
        PipelineUsage(
            backend: "openai",
            model: "gpt-4o",
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            audioSeconds: nil,
            costUSD: nil,
            durationSeconds: 1,
            completedAt: Date(),
        )
    }
}
