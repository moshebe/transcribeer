import Foundation

/// Builds + persists the `PipelineUsage` records for a session's
/// transcription and summarization. Extracted from `PipelineRunner` so the
/// runner stays under SwiftLint's type-body-length cap and the persistence
/// logic is testable in isolation.
@MainActor
enum SessionUsageRecorder {
    /// Persist `transcription_meta`. Audio duration is rederived from the
    /// session's recorded file so the same call works for both live and
    /// re-transcribe paths.
    static func recordTranscription(
        session: URL,
        config: AppConfig,
        duration: TimeInterval,
    ) {
        let backend = config.transcriptionBackend
        let model = transcriptionModel(for: backend, config: config)
        let audioSeconds = SessionManager.audioDurationSeconds(in: session)
        let cost = PricingCatalog.transcriptionCost(
            backend: backend,
            model: model,
            audioSeconds: audioSeconds,
        )
        SessionManager.setTranscriptionUsage(session, PipelineUsage(
            backend: backend,
            model: model,
            inputTokens: nil,
            outputTokens: nil,
            audioSeconds: audioSeconds,
            costUSD: cost,
            durationSeconds: duration,
            completedAt: Date(),
        ))
    }

    /// Persist `summarization_meta` using the token counts returned by the
    /// LLM and the active backend/model from `config`.
    static func recordSummarization(
        session: URL,
        config: AppConfig,
        usage: TokenUsage?,
        duration: TimeInterval,
    ) {
        let cost = PricingCatalog.summarizationCost(
            backend: config.llmBackend,
            model: config.llmModel,
            inputTokens: usage?.inputTokens,
            outputTokens: usage?.outputTokens,
        )
        SessionManager.setSummarizationUsage(session, PipelineUsage(
            backend: config.llmBackend,
            model: config.llmModel,
            inputTokens: usage?.inputTokens,
            outputTokens: usage?.outputTokens,
            audioSeconds: nil,
            costUSD: cost,
            durationSeconds: duration,
            completedAt: Date(),
        ))
    }

    /// Resolve the model id reported in `transcription_meta` for a given
    /// backend, pulling from whichever per-backend config field holds it.
    private static func transcriptionModel(for backend: String, config: AppConfig) -> String {
        switch TranscriptionBackend.from(backend) {
        case .whisperkit: config.whisperModel
        case .openai: config.openaiTranscriptionModel
        case .gemini: config.geminiTranscriptionModel
        }
    }
}
