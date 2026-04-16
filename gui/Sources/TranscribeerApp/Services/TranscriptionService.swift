import Foundation
import WhisperKit
import TranscribeerCore

/// Wraps WhisperKit for in-process speech-to-text transcription with observable state for the GUI.
@Observable @MainActor
final class TranscriptionService {
    /// Current transcription progress (nil when idle).
    var progress: Double?

    /// Current state of the loaded model.
    var modelState: ModelState = .unloaded

    private var whisperKit: WhisperKit?

    private static let modelsDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".transcribeer/models", isDirectory: true)
    }()

    /// Load (and download if needed) a WhisperKit model.
    ///
    /// - Parameter name: Model variant name (e.g. "large-v3-turbo").
    func loadModel(name: String = "openai_whisper-large-v3-turbo") async throws {
        guard modelState != .loaded else { return }

        modelState = .downloading

        let downloadBase = Self.modelsDir
        try FileManager.default.createDirectory(
            at: downloadBase, withIntermediateDirectories: true
        )

        let config = WhisperKitConfig(
            model: name,
            downloadBase: downloadBase,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: true
        )

        let kit = try await WhisperKit(config)
        kit.modelStateCallback = { [weak self] _, newState in
            Task { @MainActor in
                self?.modelState = newState
            }
        }

        whisperKit = kit
        modelState = kit.modelState
    }

    /// Transcribe an audio file to timestamped segments.
    ///
    /// - Parameters:
    ///   - audioURL: Path to the audio file (WAV, M4A, etc.).
    ///   - language: Language code (e.g. "en") or "auto" for detection.
    /// - Returns: Array of timestamped transcript segments.
    func transcribe(
        audioURL: URL,
        language: String = "auto"
    ) async throws -> [TranscriptSegment] {
        if whisperKit == nil || modelState != .loaded {
            try await loadModel()
        }

        guard let kit = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        progress = 0

        let lang: String? = language == "auto" ? nil : language
        let options = DecodingOptions(
            verbose: false,
            language: lang,
            chunkingStrategy: .vad
        )

        let observation = kit.progress.observe(
            \.fractionCompleted,
            options: [.new]
        ) { [weak self] prog, _ in
            Task { @MainActor in
                self?.progress = prog.fractionCompleted
            }
        }

        defer {
            observation.invalidate()
            progress = nil
        }

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

    /// Unload the current model and free memory.
    func unloadModel() async {
        if let kit = whisperKit {
            whisperKit = nil
            await kit.unloadModels()
        }
        modelState = .unloaded
        progress = nil
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model is not loaded."
        }
    }
}
