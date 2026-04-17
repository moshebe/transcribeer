import Foundation
import WhisperKit

/// Transcribes a long audio file by splitting it into chunks processed in parallel.
public enum ChunkedTranscriber {

    /// Audio duration (seconds) above which chunked parallel transcription is used.
    public static let chunkingThreshold: Double = 600 // 10 minutes

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
        maxConcurrency: Int = 2,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribeer-chunks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chunks = try AudioChunker.split(
            source: audioURL,
            chunkDuration: chunkDuration,
            tempDir: tempDir
        )
        guard !chunks.isEmpty else { return [] }

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

        // Load N WhisperKit instances in parallel
        let n = min(chunks.count, maxConcurrency)
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

        // Batches of N — each kit handles exactly one chunk per batch
        let batches = stride(from: 0, to: chunks.count, by: n).map {
            Array(chunks[$0..<min($0 + n, chunks.count)])
        }

        for batch in batches {
            var batchResults: [(idx: Int, offset: Double, segs: [TranscriptSegment])] = []

            try await withThrowingTaskGroup(
                of: (Int, Double, [TranscriptSegment]).self
            ) { group in
                for (batchIdx, chunk) in batch.enumerated() {
                    let kit    = kits[batchIdx]
                    let offset = chunk.startOffset
                    group.addTask {
                        let segs = try await Self.transcribeChunk(
                            url: chunk.url,
                            kit: kit,
                            language: language
                        )
                        return (batchIdx, offset, segs)
                    }
                }
                for try await (idx, offset, segs) in group {
                    batchResults.append((idx, offset, segs))
                }
            }

            batchResults.sort { $0.idx < $1.idx }
            chunkResults.append(contentsOf: batchResults.map { (offset: $0.offset, segments: $0.segs) })
            completedChunks += batch.count
            onProgress?(Double(completedChunks) / Double(totalChunks))
        }

        return mergeChunkResults(chunkResults)
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
                        end:   seg.end   + chunk.offset,
                        text:  text
                    )
                }
            }
            .sorted { $0.start < $1.start }
    }

    // MARK: - Private

    private static func transcribeChunk(
        url: URL,
        kit: WhisperKit,
        language: String
    ) async throws -> [TranscriptSegment] {
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
        return results.flatMap { result in
            result.segments.map { seg in
                TranscriptSegment(
                    start: Double(seg.start),
                    end:   Double(seg.end),
                    text:  seg.text
                )
            }
        }
    }
}
