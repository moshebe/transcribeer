import Foundation
import WhisperKit

/// A single transcribed segment with timing info.
struct TranscriptSegment: Sendable {
    let start: Double // seconds
    let end: Double
    let text: String
}

/// Wraps WhisperKit for in-process speech-to-text transcription.
///
/// The heavy `kit.transcribe(...)` call is dispatched to a detached background
/// task so the main actor stays responsive — the UI can command-tab, scroll,
/// and repaint while a 55-minute meeting is being processed.
@Observable @MainActor
final class TranscriptionService {
    /// Current transcription progress (nil when idle).
    var progress: Double?

    /// Current state of the loaded model.
    var modelState: ModelState = .unloaded

    /// Segments discovered so far in the running transcription. Cleared at the
    /// start of every `transcribe(...)` call. Drives the live preview in the
    /// transcript tab while WhisperKit is still decoding. Unlike `progress`,
    /// this carries the actual text so the user sees words as they appear.
    var liveSegments: [TranscriptSegment] = []

    private var whisperKit: WhisperKit?

    /// The currently running transcription. Stored so the caller can cancel it.
    private var activeTask: Task<[TranscriptSegment], Error>?

    private static let modelsDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".transcribeer/models", isDirectory: true)
    }()

    /// macOS 14+ compute plan: encode + decode on the Neural Engine, mel on GPU.
    /// This matches WhisperKit's recommended configuration for Apple Silicon
    /// and keeps the CPU free for UI work.
    private static let aneComputeOptions = ModelComputeOptions(
        melCompute: .cpuAndGPU,
        audioEncoderCompute: .cpuAndNeuralEngine,
        textDecoderCompute: .cpuAndNeuralEngine,
        prefillCompute: .cpuOnly,
    )

    /// Load (and download if needed) a WhisperKit model.
    ///
    /// - Parameter name: WhisperKit model identifier, matching a folder in
    ///   `argmaxinc/whisperkit-coreml` (e.g. `"openai_whisper-large-v3_turbo"`).
    ///   Legacy short names (e.g. `"large-v3-turbo"`) are migrated automatically.
    func loadModel(name: String = "openai_whisper-large-v3_turbo") async throws {
        guard modelState != .loaded else { return }

        let downloadBase = Self.modelsDir
        try FileManager.default.createDirectory(
            at: downloadBase, withIntermediateDirectories: true,
        )

        let canonical = AppConfig.canonicalWhisperModel(name)
        let cachedFolder = Self.cachedModelFolder(variant: canonical, downloadBase: downloadBase)

        // If the model is already on disk, skip the download branch entirely and
        // start from the load state. Otherwise WhisperKit would still hit the network
        // to verify the snapshot (and our UI would say "Downloading…").
        modelState = cachedFolder != nil ? .loading : .downloading

        let config = WhisperKitConfig(
            model: canonical,
            downloadBase: downloadBase,
            modelFolder: cachedFolder?.path,
            computeOptions: Self.aneComputeOptions,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: cachedFolder == nil,
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

    /// Returns the on-disk folder for a WhisperKit variant if it's already been
    /// downloaded, matching the layout `HubApi` produces under `downloadBase`.
    private static func cachedModelFolder(variant: String, downloadBase: URL) -> URL? {
        let folder = downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)

        // Minimum viable set of CoreML bundles WhisperKit needs to load.
        let required = [
            "AudioEncoder.mlmodelc",
            "TextDecoder.mlmodelc",
            "MelSpectrogram.mlmodelc",
        ]
        let fileManager = FileManager.default
        let allPresent = required.allSatisfy { name in
            fileManager.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
        return allPresent ? folder : nil
    }

    /// Transcribe an audio file to timestamped segments.
    ///
    /// The underlying WhisperKit call runs on a detached, user-initiated task
    /// so the main actor is free to service UI events throughout. Progress
    /// updates are throttled to ~10 Hz to avoid hammering SwiftUI's tracking.
    ///
    /// - Parameters:
    ///   - audioURL: Path to the audio file (WAV, M4A, etc.).
    ///   - language: Language code (e.g. "en") or "auto" for detection.
    /// - Returns: Array of timestamped transcript segments.
    func transcribe(
        audioURL: URL,
        language: String = "auto",
    ) async throws -> [TranscriptSegment] {
        if whisperKit == nil || modelState != .loaded {
            try await loadModel()
        }

        guard let kit = whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        progress = 0
        liveSegments = []

        // When language is known, skip Whisper's temperature-fallback cascade
        // (up to 5 retries per chunk at increasing temperatures). The fallback
        // is designed for mixed-language or noisy audio — with an explicit
        // language it's pure overhead and can 5× the wall time.
        //
        // `skipSpecialTokens: true` is important: WhisperKit defaults to
        // `false`, which leaks `<|startoftranscript|>`, `<|he|>`, `<|0.00|>`,
        // `<|endoftext|>` tokens into `segment.text`. With VAD chunking those
        // accumulate per chunk and make the transcript unreadable.
        let explicitLanguage = language != "auto"
        let options = DecodingOptions(
            verbose: false,
            language: explicitLanguage ? language : nil,
            temperatureFallbackCount: explicitLanguage ? 0 : 5,
            detectLanguage: !explicitLanguage,
            skipSpecialTokens: true,
            chunkingStrategy: .vad,
        )

        // Throttled, main-actor-safe progress sink. The KVO callback can fire
        // dozens of times per second; we only forward noticeable changes.
        let progressSink = ProgressSink { [weak self] value in
            Task { @MainActor in
                self?.progress = value
            }
        }

        let observation = kit.progress.observe(
            \.fractionCompleted,
            options: [.new],
        ) { reported, _ in
            progressSink.submit(reported.fractionCompleted)
        }

        // Stream discovered segments to the UI. WhisperKit invokes this from
        // a background queue, so hop to the main actor before mutating state.
        // Segments may arrive slightly out of order with VAD chunking — the
        // view sorts by `start` before rendering.
        kit.segmentDiscoveryCallback = { [weak self] segments in
            let mapped = segments.map { seg in
                TranscriptSegment(
                    start: Double(seg.start),
                    end: Double(seg.end),
                    text: seg.text.trimmingCharacters(in: .whitespaces),
                )
            }
            Task { @MainActor in
                self?.liveSegments.append(contentsOf: mapped)
            }
        }

        defer {
            observation.invalidate()
            kit.segmentDiscoveryCallback = nil
            progress = nil
            activeTask = nil
        }

        let audioPath = audioURL.path
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let results = try await kit.transcribe(
                audioPath: audioPath,
                decodeOptions: options,
            )
            return results.flatMap(\.segments).map { segment in
                TranscriptSegment(
                    start: Double(segment.start),
                    end: Double(segment.end),
                    text: segment.text.trimmingCharacters(in: .whitespaces),
                )
            }
        }
        activeTask = task

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Cancel any in-flight transcription. The returned task will throw
    /// `CancellationError`.
    func cancel() {
        activeTask?.cancel()
    }

    /// Unload the current model and free memory.
    func unloadModel() async {
        if let kit = whisperKit {
            whisperKit = nil
            await kit.unloadModels()
        }
        modelState = .unloaded
        progress = nil
        liveSegments = []
    }
}

/// Rate-limits progress callbacks so the main actor isn't flooded with updates.
///
/// Sendable because WhisperKit's KVO callback crosses thread boundaries. We
/// use an `NSLock` rather than an actor to keep the submit call synchronous.
private final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lastValue: Double = -1
    private let emit: @Sendable (Double) -> Void

    /// Minimum delta before a new value is forwarded (≈ 1 percentage point).
    private static let threshold: Double = 0.01

    init(emit: @escaping @Sendable (Double) -> Void) {
        self.emit = emit
    }

    func submit(_ value: Double) {
        let shouldEmit = lock.withLock {
            let crossedThreshold = value == 1.0 || value == 0 || value - lastValue >= Self.threshold
            if crossedThreshold { lastValue = value }
            return crossedThreshold
        }
        if shouldEmit { emit(value) }
    }
}

enum TranscriptionError: LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "Whisper model is not loaded."
        }
    }
}
