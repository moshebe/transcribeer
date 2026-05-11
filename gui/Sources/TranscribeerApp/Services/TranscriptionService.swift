import CaptureCore
import Foundation
import WhisperKit
import TranscribeerCore

/// A single transcribed segment with timing info.
struct TranscriptSegment: Sendable {
    let start: Double // seconds
    let end: Double
    let text: String
    let speaker: String

    init(start: Double, end: Double, text: String, speaker: String = "") {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
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

    /// Progress for the mic source in a dual-source transcription.
    var micProgress: Double?

    /// Progress for the system-audio source in a dual-source transcription.
    var sysProgress: Double?

    /// Per-source progress snapshots from the cloud tracker. Carry chunk
    /// counts in addition to the fraction so the UI can render
    /// "Transcribing N of M chunks". `nil` outside cloud transcription.
    var micSnapshot: CloudProgressTracker.Snapshot?
    var sysSnapshot: CloudProgressTracker.Snapshot?

    /// Display name of the active cloud backend ("OpenAI", "Gemini"). Set
    /// at the start of `transcribeCloud` and cleared on completion so
    /// `transcriptionPhase` can mention which API is being hit.
    var cloudBackendName: String?

    /// Human-readable description of what the transcription pipeline is
    /// doing right now. SwiftUI re-reads this whenever the underlying
    /// snapshots change. Returns `nil` when there's nothing useful to show
    /// (so the view falls back to the legacy "Transcribing…" label).
    var transcriptionPhase: String? {
        guard let backendName = cloudBackendName else { return nil }
        let snapshots = [micSnapshot, sysSnapshot].compactMap { $0 }
        let total = snapshots.reduce(0) { $0 + $1.total }
        guard total > 0 else { return "Preparing audio…" }
        let completed = snapshots.reduce(0) { $0 + $1.completed }
        if completed == total { return "Finalizing transcript…" }
        let inFlight = snapshots.reduce(0) { $0 + $1.inFlight }
        if completed == 0, inFlight == 0 { return "Uploading to \(backendName)…" }
        return "Transcribing \(completed + 1) of \(total) chunks · \(backendName)"
    }

    /// Current state of the loaded model.
    var modelState: ModelState = .unloaded

    /// Segments discovered so far in the running transcription. Cleared at the
    /// start of every `transcribe(...)` call. Drives the live preview in the
    /// transcript tab while WhisperKit is still decoding. Unlike `progress`,
    /// this carries the actual text so the user sees words as they appear.
    var liveSegments: [TranscriptSegment] = []

    private var whisperKit: WhisperKit?
    private var loadedModelName: String?
    private var loadedModelRepo: String?

    /// The currently running transcription. Stored so the caller can cancel it.
    private var activeTask: Task<[TranscriptSegment], Error>?
    private var dualTask: Task<[TranscribeerCore.LabeledSegment], Error>?
    private var cloudTask: Task<[LabeledSegment], Error>?

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
        prefillCompute: .cpuOnly
    )

    /// Load (and download if needed) a WhisperKit model.
    ///
    /// - Parameters:
    ///   - name: WhisperKit model identifier (e.g. `"openai_whisper-large-v3_turbo"`).
    ///     Legacy short names (e.g. `"large-v3-turbo"`) are migrated automatically.
    ///   - repo: Optional HuggingFace repo (`"owner/repo-name"`) to download from.
    ///     Pass `nil` to use the default `argmaxinc/whisperkit-coreml` repo.
    func loadModel(name: String = "openai_whisper-large-v3_turbo", repo: String? = nil) async throws {
        let modelRepo = repo.flatMap { $0.isEmpty ? nil : $0 }
        let alreadyLoaded = modelState == .loaded
            && loadedModelName == name
            && loadedModelRepo == modelRepo
        guard !alreadyLoaded else { return }

        let downloadBase = Self.modelsDir
        try FileManager.default.createDirectory(
            at: downloadBase, withIntermediateDirectories: true
        )

        let canonical = AppConfig.canonicalWhisperModel(name)
        let cachedFolder = Self.cachedModelFolder(variant: canonical, downloadBase: downloadBase, repo: modelRepo)

        // If the model is already on disk, skip the download branch entirely and
        // start from the load state. Otherwise WhisperKit would still hit the network
        // to verify the snapshot (and our UI would say "Downloading…").
        modelState = cachedFolder != nil ? .loading : .downloading

        let config = WhisperKitConfig(
            model: canonical,
            downloadBase: downloadBase,
            modelRepo: modelRepo,
            modelFolder: cachedFolder?.path,
            computeOptions: Self.aneComputeOptions,
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: true,
            download: cachedFolder == nil
        )

        let kit = try await WhisperKit(config)
        kit.modelStateCallback = { [weak self] _, newState in
            Task { @MainActor in
                self?.modelState = newState
            }
        }

        whisperKit = kit
        modelState = kit.modelState
        loadedModelName = name
        loadedModelRepo = modelRepo
    }

    /// Returns the on-disk folder for a WhisperKit variant if it's already been
    /// downloaded, matching the layout `HubApi` produces under `downloadBase`.
    private static func cachedModelFolder(variant: String, downloadBase: URL, repo: String?) -> URL? {
        let owner: String
        let repoName: String
        if let repo {
            let parts = repo.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            owner = String(parts[0])
            repoName = String(parts[1])
        } else {
            owner = "argmaxinc"
            repoName = "whisperkit-coreml"
        }

        let folder = downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(repoName, isDirectory: true)
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

    /// Transcribe a session directory.
    ///
    /// Picks the backend from `config.transcriptionBackend`:
    /// - `whisperkit` runs locally via `DualSourceTranscriber` (current path).
    /// - `openai` / `gemini` call the cloud API per audio source and merge
    ///   segments using the same timing/labelling rules.
    ///
    /// - Returns: Formatted transcript text.
    func transcribe(session: URL, config: AppConfig) async throws -> String {
        let timing = try readTiming(from: session)
        let backend = TranscriptionBackend.from(config.transcriptionBackend)
        switch backend {
        case .whisperkit:
            return try await transcribeLocal(session: session, config: config, timing: timing)
        case .openai, .gemini:
            return try await transcribeCloud(
                session: session,
                config: config,
                timing: timing,
                backend: backend
            )
        }
    }

    /// Read `timing.json` if present. Returns nil-anchored timing when the
    /// file is missing; throws when the file exists but cannot be parsed so
    /// data corruption is surfaced rather than masked.
    private func readTiming(from session: URL) throws -> DualSourceTranscriber.TimingInfo {
        let timingURL = session.appendingPathComponent("timing.json")
        guard FileManager.default.fileExists(atPath: timingURL.path) else {
            return .init(micStartEpoch: nil, sysStartEpoch: nil)
        }
        let metadata = try TimingMetadata.read(from: timingURL)
        return .init(
            micStartEpoch: metadata.micStartEpoch,
            sysStartEpoch: metadata.sysStartEpoch
        )
    }

    // MARK: - Local (WhisperKit)

    private func transcribeLocal(
        session: URL,
        config: AppConfig,
        timing: DualSourceTranscriber.TimingInfo
    ) async throws -> String {
        var coreCfg = TranscribeerCore.AppConfig()
        coreCfg.language = config.language
        coreCfg.whisperModel = config.whisperModel
        coreCfg.whisperModelRepo = config.whisperModelRepo
        coreCfg.diarization = config.diarization
        coreCfg.numSpeakers = config.numSpeakers
        coreCfg.audio.selfLabel = config.audio.selfLabel
        coreCfg.audio.otherLabel = config.audio.otherLabel

        progress = 0
        micProgress = 0
        sysProgress = 0
        liveSegments = []

        let onMicProgress: @Sendable (Double) -> Void = { value in
            Task { @MainActor in self.applyMicProgress(value) }
        }
        let onSysProgress: @Sendable (Double) -> Void = { value in
            Task { @MainActor in self.applySysProgress(value) }
        }
        let task = Task.detached(priority: .userInitiated) { () -> [TranscribeerCore.LabeledSegment] in
            try Task.checkCancellation()
            return try await DualSourceTranscriber.transcribe(
                session: session,
                cfg: coreCfg,
                timing: timing,
                onMicProgress: onMicProgress,
                onSysProgress: onSysProgress
            )
        }
        dualTask = task

        defer {
            progress = nil
            micProgress = nil
            sysProgress = nil
            dualTask = nil
        }

        let segments = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }

        let appSegments = segments.map(Self.toLabeledSegment)
        liveSegments = appSegments.map(Self.toLiveSegment)
        return TranscriptFormatter.formatDual(appSegments)
    }

    // MARK: - Cloud (OpenAI / Gemini)

    /// Cloud-backend equivalent of the local dual-source path. Calls the API
    /// once per present audio source, applies wall-clock offsets, tags mic
    /// segments as `selfLabel` and sys segments as `otherLabel`, then
    /// interleaves by start time.
    private func transcribeCloud(
        session: URL,
        config: AppConfig,
        timing: DualSourceTranscriber.TimingInfo,
        backend: TranscriptionBackend
    ) async throws -> String {
        let micURL = session.appendingPathComponent("audio.mic.caf")
        let sysURL = session.appendingPathComponent("audio.sys.caf")
        let mixedURL = session.appendingPathComponent("audio.m4a")
        let fileManager = FileManager.default
        let hasMic = fileManager.fileExists(atPath: micURL.path)
        let hasSys = fileManager.fileExists(atPath: sysURL.path)
        let hasMixed = fileManager.fileExists(atPath: mixedURL.path)

        let model = backend == .openai
            ? config.openaiTranscriptionModel
            : config.geminiTranscriptionModel

        progress = 0
        micProgress = hasMic ? 0 : nil
        sysProgress = hasSys ? 0 : nil
        micSnapshot = nil
        sysSnapshot = nil
        cloudBackendName = backend.displayName
        liveSegments = []

        let onMicProgress: @Sendable (CloudProgressTracker.Snapshot) -> Void = { snap in
            Task { @MainActor in self.applyMicSnapshot(snap) }
        }
        let onSysProgress: @Sendable (CloudProgressTracker.Snapshot) -> Void = { snap in
            Task { @MainActor in self.applySysSnapshot(snap) }
        }
        let dualCfg = CloudTranscriptionCoordinator.DualConfig(
            backend: backend,
            micURL: hasMic ? micURL : nil,
            sysURL: hasSys ? sysURL : nil,
            timing: timing,
            model: model,
            language: config.language,
            selfLabel: config.audio.selfLabel,
            otherLabel: config.audio.otherLabel,
            onMicProgress: onMicProgress,
            onSysProgress: onSysProgress
        )
        let task = Task.detached(priority: .userInitiated) { () -> [LabeledSegment] in
            try Task.checkCancellation()
            if hasMic || hasSys {
                return try await CloudTranscriptionCoordinator.runDual(dualCfg)
            }
            guard hasMixed else { return [] }
            return try await CloudTranscriptionCoordinator.runMixed(
                backend: backend,
                audioURL: mixedURL,
                model: model,
                language: config.language,
                onProgress: onMicProgress
            )
        }
        cloudTask = task

        defer {
            progress = nil
            micProgress = nil
            sysProgress = nil
            micSnapshot = nil
            sysSnapshot = nil
            cloudBackendName = nil
            cloudTask = nil
        }

        let appSegments = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }

        liveSegments = appSegments.map(Self.toLiveSegment)
        return TranscriptFormatter.formatDual(appSegments)
    }

    /// Map a Core segment to the App-layer labelled segment used by the
    /// transcript formatter.
    private static func toLabeledSegment(_ seg: TranscribeerCore.LabeledSegment) -> LabeledSegment {
        LabeledSegment(start: seg.start, end: seg.end, speaker: seg.speaker, text: seg.text)
    }

    /// Map a labelled segment to the live-preview type rendered in the UI.
    private static func toLiveSegment(_ seg: LabeledSegment) -> TranscriptSegment {
        TranscriptSegment(start: seg.start, end: seg.end, text: seg.text, speaker: seg.speaker)
    }

    private func applyMicProgress(_ value: Double) {
        guard micProgress != value else { return }
        micProgress = value
        updateCombinedProgress()
    }

    private func applySysProgress(_ value: Double) {
        guard sysProgress != value else { return }
        sysProgress = value
        updateCombinedProgress()
    }

    /// Snapshot-aware variants used by the cloud path. Store the snapshot
    /// (drives `transcriptionPhase`) and pipe the fraction into the
    /// existing per-source progress state so the bar keeps working.
    private func applyMicSnapshot(_ snapshot: CloudProgressTracker.Snapshot) {
        micSnapshot = snapshot
        applyMicProgress(snapshot.fraction)
    }

    private func applySysSnapshot(_ snapshot: CloudProgressTracker.Snapshot) {
        sysSnapshot = snapshot
        applySysProgress(snapshot.fraction)
    }

    private func updateCombinedProgress() {
        switch (micProgress, sysProgress) {
        case (nil, nil):                   progress = nil
        case let (mic?, nil):              progress = mic
        case let (nil, sys?):              progress = sys
        case let (mic?, sys?):             progress = (mic + sys) / 2
        }
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
        language: String = "auto"
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
        // language it's pure overhead and can 5x the wall time.
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
            chunkingStrategy: .vad
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
            options: [.new]
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
                    text: seg.text.trimmingCharacters(in: .whitespaces)
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
                decodeOptions: options
            )
            return results.flatMap(\.segments).map { segment in
                TranscriptSegment(
                    start: Double(segment.start),
                    end: Double(segment.end),
                    text: segment.text.trimmingCharacters(in: .whitespaces)
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
        dualTask?.cancel()
        cloudTask?.cancel()
    }

    /// Unload the current model and free memory.
    func unloadModel() async {
        if let kit = whisperKit {
            whisperKit = nil
            await kit.unloadModels()
        }
        modelState = .unloaded
        loadedModelName = nil
        loadedModelRepo = nil
        progress = nil
        micProgress = nil
        sysProgress = nil
        micSnapshot = nil
        sysSnapshot = nil
        cloudBackendName = nil
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

    /// Minimum delta before a new value is forwarded (1 percentage point).
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
    case missingAPIKey(backend: String, envVar: String)
    case httpError(backend: String, status: Int, body: String)
    case invalidResponse(backend: String, detail: String)
    case network(backend: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Whisper model is not loaded."
        case let .missingAPIKey(backend, envVar):
            let envHint = envVar.isEmpty ? "" : " or set $\(envVar)"
            return "\(backend) API key missing — add it in Settings → Transcription\(envHint)."
        case let .httpError(backend, status, body):
            return "\(backend) transcription failed (HTTP \(status)): \(body)"
        case let .invalidResponse(backend, detail):
            return "\(backend) returned an unexpected response: \(detail)"
        case let .network(backend, detail):
            return "\(backend) network error: \(detail)"
        }
    }
}
