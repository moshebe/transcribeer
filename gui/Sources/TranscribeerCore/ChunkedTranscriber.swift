import Foundation
import WhisperKit

/// Transcribes a long audio file by splitting it into chunks processed in parallel.
public enum ChunkedTranscriber {
    /// Audio duration (seconds) above which chunked parallel transcription is used.
    public static let chunkingThreshold: Double = 600 // 10 minutes

    /// Result of a chunked transcription: the merged segments plus the language
    /// WhisperKit detected when `language == "auto"`. `detectedLanguage` is `nil`
    /// when an explicit language code was requested.
    public struct TranscriptionOutput: Sendable {
        public let segments: [TranscriptSegment]
        /// Two-letter ISO 639-1 code (e.g. `"he"`, `"en"`) detected by Whisper.
        /// `nil` when the caller supplied an explicit language rather than `"auto"`.
        public let detectedLanguage: String?

        public init(segments: [TranscriptSegment], detectedLanguage: String?) {
            self.segments = segments
            self.detectedLanguage = detectedLanguage
        }
    }

    /// Transcribe `audioURL` using N parallel WhisperKit instances.
    ///
    /// - Parameters:
    ///   - audioURL: The full WAV file to transcribe.
    ///   - modelName: WhisperKit model name (e.g. `"openai_whisper-large-v3_turbo"`).
    ///   - modelRepo: Optional HuggingFace repo for a custom model (pass nil to use default).
    ///   - downloadBase: Directory where models are cached.
    ///   - language: Language code or `"auto"`.
    ///   - chunkDuration: Duration of each chunk in seconds (default 600).
    ///   - maxConcurrency: Maximum parallel WhisperKit instances (default 2).
    ///   - onProgress: Called with fraction (0–1) as chunks complete.
    public static func transcribe(
        audioURL: URL,
        modelName: String,
        modelRepo: String?,
        downloadBase: URL,
        language: String,
        chunkDuration: Double = 600,
        budget: TranscriptionBudget = .standard,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> TranscriptionOutput {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribeer-chunks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chunks = try AudioChunker.split(
            source: audioURL,
            chunkDuration: chunkDuration,
            tempDir: tempDir
        )
        guard !chunks.isEmpty else {
            return TranscriptionOutput(segments: [], detectedLanguage: nil)
        }

        let kitConfig = WhisperKitConfig(
            model: modelName,
            downloadBase: downloadBase,
            modelRepo: modelRepo,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: true
        )

        if !budget.allowParallel {
            return try await transcribeSequential(
                chunks: chunks,
                kitConfig: kitConfig,
                language: language,
                onProgress: onProgress
            )
        }

        // Load N WhisperKit instances in parallel
        let n = min(chunks.count, budget.maxConcurrency)
        var kits: [WhisperKit] = []
        try await withThrowingTaskGroup(of: WhisperKit.self) { group in
            for _ in 0..<n {
                group.addTask { try await WhisperKit(kitConfig) }
            }
            for try await kit in group {
                kits.append(kit)
            }
        }

        let totalChunks = chunks.count
        var completedChunks = 0
        var chunkResults: [(offset: Double, segments: [TranscriptSegment])] = []
        // Capture the language WhisperKit reported for the first non-empty chunk.
        // Only meaningful when `language == "auto"`; ignored otherwise.
        var firstDetectedLanguage: String?

        // Batches of N — each kit handles exactly one chunk per batch
        let batches = stride(from: 0, to: chunks.count, by: n).map { start in
            Array(chunks[start..<min(start + n, chunks.count)])
        }

        for batch in batches {
            var batchResults: [(idx: Int, offset: Double, output: ChunkOutput)] = []

            try await withThrowingTaskGroup(
                of: (Int, Double, ChunkOutput).self
            ) { group in
                for (batchIdx, chunk) in batch.enumerated() {
                    let kit = kits[batchIdx]
                    let offset = chunk.startOffset
                    group.addTask {
                        let out = try await Self.transcribeChunk(
                            url: chunk.url,
                            kit: kit,
                            language: language
                        )
                        return (batchIdx, offset, out)
                    }
                }
                for try await (idx, offset, out) in group {
                    batchResults.append((idx, offset, out))
                }
            }

            batchResults.sort { $0.idx < $1.idx }
            for r in batchResults {
                chunkResults.append((offset: r.offset, segments: r.output.segments))
                if firstDetectedLanguage == nil, let lang = r.output.detectedLanguage {
                    firstDetectedLanguage = lang
                }
            }
            completedChunks += batch.count
            onProgress?(Double(completedChunks) / Double(totalChunks))
        }

        let segments = mergeChunkResults(chunkResults)
        let detected = language == "auto" ? firstDetectedLanguage : nil
        return TranscriptionOutput(segments: segments, detectedLanguage: detected)
    }

    /// Merge per-chunk results into a single sorted segment array.
    /// Public for unit testing without WhisperKit.
    public static func mergeChunkResults(
        _ chunkResults: [(offset: Double, segments: [TranscriptSegment])]
    ) -> [TranscriptSegment] {
        chunkResults
            .flatMap { chunk in
                chunk.segments.compactMap { seg in
                    let text = seg.text.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return nil }
                    return TranscriptSegment(
                        start: seg.start + chunk.offset,
                        end: seg.end + chunk.offset,
                        text: text
                    )
                }
            }
            .sorted { $0.start < $1.start }
    }

    // MARK: - Private

    /// Sequential path: one WhisperKit instance, processes chunks one at a time.
    /// Used when `budget.allowParallel == false` (e.g. memory pressure critical).
    private static func transcribeSequential(
        chunks: [AudioChunker.Chunk],
        kitConfig: WhisperKitConfig,
        language: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> TranscriptionOutput {
        let kit = try await WhisperKit(kitConfig)
        var chunkResults: [(offset: Double, segments: [TranscriptSegment])] = []
        var firstDetectedLanguage: String?
        let total = chunks.count

        for (idx, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let out = try await transcribeChunk(url: chunk.url, kit: kit, language: language)
            chunkResults.append((offset: chunk.startOffset, segments: out.segments))
            if firstDetectedLanguage == nil { firstDetectedLanguage = out.detectedLanguage }
            onProgress?(Double(idx + 1) / Double(total))
        }

        let segments = mergeChunkResults(chunkResults)
        let detected = language == "auto" ? firstDetectedLanguage : nil
        return TranscriptionOutput(segments: segments, detectedLanguage: detected)
    }

    /// Intermediate result per chunk, carrying language alongside segments.
    private struct ChunkOutput: Sendable {
        let segments: [TranscriptSegment]
        /// Language code WhisperKit assigned to this chunk.
        /// Non-nil only when the caller requested auto-detection and a result was returned.
        let detectedLanguage: String?
    }

    private static func transcribeChunk(
        url: URL,
        kit: WhisperKit,
        language: String
    ) async throws -> ChunkOutput {
        let lang: String? = language == "auto" ? nil : language
        let options = DecodingOptions(
            verbose: false,
            language: lang,
            chunkingStrategy: .vad
        )
        let results: [TranscriptionResult] = try await kit.transcribe(
            audioPath: url.path,
            decodeOptions: options
        )
        let segments = results.flatMap { result in
            result.segments.map { seg in
                TranscriptSegment(
                    start: Double(seg.start),
                    end: Double(seg.end),
                    text: seg.text
                )
            }
        }
        // Capture the language detected for the first non-empty result when in auto mode.
        let detected = language == "auto"
            ? results.first(where: { !$0.language.isEmpty })?.language
            : nil
        return ChunkOutput(segments: segments, detectedLanguage: detected)
    }
}
