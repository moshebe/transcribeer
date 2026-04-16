import Foundation
import WhisperKit

/// A single transcribed segment with timing info.
public struct TranscriptSegment: Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// Transcribe an audio file using WhisperKit (downloads model on first call).
///
/// - Parameters:
///   - audioURL: Path to the audio file.
///   - language: Language code (e.g. "he", "en") or "auto" for detection.
///   - modelName: WhisperKit model name (e.g. "openai_whisper-large-v3-turbo").
///   - modelsDir: Directory where models are downloaded and cached.
///   - onProgress: Optional progress callback (0.0 – 1.0).
public func transcribeAudio(
    audioURL: URL,
    language: String,
    modelName: String,
    modelsDir: URL,
    onProgress: (@Sendable (Double) -> Void)? = nil
) async throws -> [TranscriptSegment] {
    try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

    let config = WhisperKitConfig(
        model: modelName,
        downloadBase: modelsDir,
        verbose: false,
        logLevel: .none,
        prewarm: true,
        load: true,
        download: true
    )

    let kit = try await WhisperKit(config)

    var observation: NSKeyValueObservation?
    if let onProgress {
        observation = kit.progress.observe(\.fractionCompleted, options: [.new]) { prog, _ in
            onProgress(prog.fractionCompleted)
        }
    }
    defer { observation?.invalidate() }

    let lang: String? = language == "auto" ? nil : language
    let options = DecodingOptions(
        verbose: false,
        language: lang,
        chunkingStrategy: .vad
    )

    let results: [TranscriptionResult] = try await kit.transcribe(
        audioPath: audioURL.path,
        decodeOptions: options
    )

    return results.flatMap { result in
        result.segments.map { seg in
            TranscriptSegment(
                start: Double(seg.start),
                end: Double(seg.end),
                text: seg.text.trimmingCharacters(in: .whitespaces)
            )
        }
    }
}
