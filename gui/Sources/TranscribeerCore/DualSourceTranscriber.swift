import Foundation
import os

private let logger = Logger(subsystem: "com.transcribeer", category: "DualSourceTranscriber")

/// Transcribes dual-source (mic + system audio) sessions or falls back to
/// legacy single-file transcription.
///
/// The dual path runs `ChunkedTranscriber` in parallel on both CAFs, offsets
/// timestamps into a common timeline using `TimingInfo`, tags mic segments as
/// "self" and sys segments as "other", then interleaves by start time.
///
/// The legacy path transcribes `audio.m4a` and optionally runs diarization.
public enum DualSourceTranscriber {
    /// Wall-clock anchors for aligning the two streams.
    public struct TimingInfo: Sendable {
        public let micStartEpoch: Double?
        public let sysStartEpoch: Double?

        public init(micStartEpoch: Double?, sysStartEpoch: Double?) {
            self.micStartEpoch = micStartEpoch
            self.sysStartEpoch = sysStartEpoch
        }
    }

    // MARK: - Public API

    /// Transcribe a session directory.
    ///
    /// - If `audio.mic.caf` or `audio.sys.caf` exists, runs the dual path.
    /// - Otherwise falls back to `audio.m4a` legacy transcription.
    public static func transcribe(
        session: URL,
        cfg: AppConfig,
        timing: TimingInfo,
        onMicProgress: (@Sendable (Double) -> Void)? = nil,
        onSysProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [LabeledSegment] {
        let micURL = session.appendingPathComponent("audio.mic.caf")
        let sysURL = session.appendingPathComponent("audio.sys.caf")

        let hasMic = FileManager.default.fileExists(atPath: micURL.path)
        let hasSys = FileManager.default.fileExists(atPath: sysURL.path)

        if hasMic || hasSys {
            return try await transcribeDual(
                mic: hasMic ? micURL : nil,
                sys: hasSys ? sysURL : nil,
                timing: timing,
                cfg: cfg,
                progress: .init(mic: onMicProgress, sys: onSysProgress)
            )
        }

        let mixedURL = session.appendingPathComponent("audio.m4a")
        return try await transcribeLegacyMixed(
            mixed: mixedURL,
            cfg: cfg,
            onProgress: onMicProgress
        )
    }

    // MARK: - Test seams

    /// Swappable diarization backend for unit testing.
    internal static var diarizeFunc: (
        _ audioURL: URL,
        _ numSpeakers: Int?
    ) async throws -> [DiarSegment] = { audioURL, numSpeakers in
        try await DiarizationService.diarize(audioURL: audioURL, numSpeakers: numSpeakers)
    }

    /// Swappable chunk transcription backend for unit testing.
    internal static var transcribeChunkFunc: (
        _ audioURL: URL,
        _ modelName: String,
        _ modelRepo: String?,
        _ downloadBase: URL,
        _ language: String,
        _ maxConcurrency: Int,
        _ onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [TranscriptSegment] = defaultTranscribeChunk

    // swiftlint:disable:next function_parameter_count
    private static func defaultTranscribeChunk(
        audioURL: URL,
        modelName: String,
        modelRepo: String?,
        downloadBase: URL,
        language: String,
        maxConcurrency: Int,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [TranscriptSegment] {
        try await ChunkedTranscriber.transcribe(
            audioURL: audioURL,
            modelName: modelName,
            modelRepo: modelRepo,
            downloadBase: downloadBase,
            language: language,
            maxConcurrency: maxConcurrency,
            onProgress: onProgress
        )
    }

    /// Swappable audio-validation backend for unit testing.
    internal static var ensureAudibleFunc: (_ url: URL) throws -> Void = { url in
        try AudioValidation.ensureAudibleSignal(at: url)
    }

    // MARK: - Dual source

    internal struct ProgressCallbacks: Sendable {
        let mic: (@Sendable (Double) -> Void)?
        let sys: (@Sendable (Double) -> Void)?
    }

    internal static func transcribeDual(
        mic: URL?,
        sys: URL?,
        timing: TimingInfo,
        cfg: AppConfig,
        progress: ProgressCallbacks
    ) async throws -> [LabeledSegment] {
        if timing.micStartEpoch == nil && timing.sysStartEpoch == nil {
            logger.warning("timing.json missing; assuming both streams start at epoch 0")
        }

        let modelRepo = cfg.whisperModelRepo.isEmpty ? nil : cfg.whisperModelRepo
        let modelsDir = AppConfig.modelsDir

        // Silent-one-side handling: if a source is present on disk but has no
        // audible signal (e.g. mic denied, user muted, other participant
        // didn't speak), skip just that source instead of failing the whole
        // transcription. Without this, a common "one participant quiet" case
        // would hard-fail the pipeline.
        async let micTask: [TranscriptSegment]? = {
            guard let mic else { return nil }
            try Task.checkCancellation()
            do {
                try ensureAudibleFunc(mic)
            } catch {
                logger.info("mic audio silent, skipping: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            return try await transcribeChunkFunc(
                mic,
                cfg.whisperModel,
                modelRepo,
                modelsDir,
                cfg.language,
                1,
                progress.mic
            )
        }()

        async let sysTask: [TranscriptSegment]? = {
            guard let sys else { return nil }
            try Task.checkCancellation()
            do {
                try ensureAudibleFunc(sys)
            } catch {
                logger.info("sys audio silent, skipping: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            return try await transcribeChunkFunc(
                sys,
                cfg.whisperModel,
                modelRepo,
                modelsDir,
                cfg.language,
                1,
                progress.sys
            )
        }()

        let micSegments = try await micTask
        let sysSegments = try await sysTask

        // Both sources came back empty — nothing to transcribe. Surface an
        // `.silent`-equivalent so the caller can treat it as a failed session.
        if (micSegments?.isEmpty ?? true) && (sysSegments?.isEmpty ?? true) {
            throw AudioValidationError.silent(
                url: mic ?? sys ?? URL(fileURLWithPath: "/"),
                probeSeconds: 0
            )
        }

        let sessionStart = min(timing.micStartEpoch ?? 0, timing.sysStartEpoch ?? 0)
        let micOffset = (timing.micStartEpoch ?? 0) - sessionStart
        let sysOffset = (timing.sysStartEpoch ?? 0) - sessionStart

        let micLabeled = try await labelMicSegments(
            micSegments: micSegments,
            micURL: mic,
            offset: micOffset,
            cfg: cfg
        )
        let sysLabeled = labelSysSegments(
            sysSegments: sysSegments,
            offset: sysOffset,
            otherLabel: cfg.audio.otherLabel
        )

        return merge(mic: micLabeled, sys: sysLabeled, otherLabel: cfg.audio.otherLabel)
    }

    private static func labelMicSegments(
        micSegments: [TranscriptSegment]?,
        micURL: URL?,
        offset: Double,
        cfg: AppConfig
    ) async throws -> [LabeledSegment] {
        guard let micSegments, let micURL else { return [] }

        if cfg.audio.diarizeMicMultiuser {
            let diarSegments = try await diarizeFunc(
                micURL,
                cfg.numSpeakers > 0 ? cfg.numSpeakers : nil
            )
            let assigned = TranscriptFormatter.assignSpeakers(
                whisperSegments: micSegments,
                diarSegments: diarSegments
            )
            return assigned.map { seg in
                LabeledSegment(
                    start: seg.start + offset,
                    end: seg.end + offset,
                    speaker: seg.speaker,
                    text: seg.text
                )
            }
        }

        return micSegments.map { shifted($0, offset: offset, speaker: cfg.audio.selfLabel) }
    }

    private static func labelSysSegments(
        sysSegments: [TranscriptSegment]?,
        offset: Double,
        otherLabel: String
    ) -> [LabeledSegment] {
        guard let sysSegments else { return [] }
        return sysSegments.map { shifted($0, offset: offset, speaker: otherLabel) }
    }

    /// Apply a timeline offset and tag a whisper segment with a speaker label.
    private static func shifted(
        _ seg: TranscriptSegment,
        offset: Double,
        speaker: String
    ) -> LabeledSegment {
        LabeledSegment(
            start: seg.start + offset,
            end: seg.end + offset,
            speaker: speaker,
            text: seg.text
        )
    }

    private static func merge(
        mic: [LabeledSegment],
        sys: [LabeledSegment],
        otherLabel: String
    ) -> [LabeledSegment] {
        let labeled = mic + sys
        return labeled.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            let aIsMic = a.speaker != otherLabel
            let bIsMic = b.speaker != otherLabel
            return aIsMic && !bIsMic
        }
    }

    /// Pure logic: offset, tag, and interleave mic + sys segments.
    ///
    /// Public so the cloud transcription path in `TranscribeerApp` can
    /// reuse the same offset/labelling rules without re-implementing the
    /// timeline math, and so unit tests can call it without WhisperKit.
    public static func mergeAndTag(
        micSegments: [TranscriptSegment]?,
        sysSegments: [TranscriptSegment]?,
        timing: TimingInfo,
        selfLabel: String,
        otherLabel: String
    ) -> [LabeledSegment] {
        let sessionStart = min(timing.micStartEpoch ?? 0, timing.sysStartEpoch ?? 0)
        let micOffset = (timing.micStartEpoch ?? 0) - sessionStart
        let sysOffset = (timing.sysStartEpoch ?? 0) - sessionStart

        let mic = (micSegments ?? []).map { shifted($0, offset: micOffset, speaker: selfLabel) }
        let sys = (sysSegments ?? []).map { shifted($0, offset: sysOffset, speaker: otherLabel) }

        // Stable interleave: earlier start wins; on ties, mic (self) comes first.
        return (mic + sys).sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            return a.speaker == selfLabel && b.speaker != selfLabel
        }
    }

    // MARK: - Legacy mixed

    private static func transcribeLegacyMixed(
        mixed: URL,
        cfg: AppConfig,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [LabeledSegment] {
        try AudioValidation.ensureAudibleSignal(at: mixed)

        let segments = try await ChunkedTranscriber.transcribe(
            audioURL: mixed,
            modelName: cfg.whisperModel,
            modelRepo: cfg.whisperModelRepo.isEmpty ? nil : cfg.whisperModelRepo,
            downloadBase: AppConfig.modelsDir,
            language: cfg.language,
            onProgress: onProgress
        )

        if cfg.diarization == "off" || cfg.diarization == "none" {
            return segments.map { seg in
                LabeledSegment(start: seg.start, end: seg.end, speaker: "Speaker", text: seg.text)
            }
        }

        let diarSegments = try await DiarizationService.diarize(
            audioURL: mixed,
            numSpeakers: cfg.numSpeakers > 0 ? cfg.numSpeakers : nil
        )

        return TranscriptFormatter.assignSpeakers(
            whisperSegments: segments,
            diarSegments: diarSegments
        )
    }
}
