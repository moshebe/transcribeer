import Foundation
import TranscribeerCore

/// Stateless helpers that orchestrate cloud transcription for a session
/// directory: per-source API calls, silence checks, and merging mic + sys
/// streams using the same timing/labelling rules the local path uses.
///
/// Lives outside `TranscriptionService` so the @MainActor-bound class body
/// stays focused on UI-facing state and stays under the file/type length
/// caps; the work itself is pure and runs off-actor.
enum CloudTranscriptionCoordinator {
    struct DualConfig: Sendable {
        let backend: TranscriptionBackend
        let micURL: URL?
        let sysURL: URL?
        let timing: DualSourceTranscriber.TimingInfo
        let model: String
        let language: String
        let selfLabel: String
        let otherLabel: String
        let onMicProgress: @Sendable (CloudProgressTracker.Snapshot) -> Void
        let onSysProgress: @Sendable (CloudProgressTracker.Snapshot) -> Void
    }

    /// Transcribe both sources in parallel via the cloud API, drop silent
    /// sources, and merge into a single labelled timeline. Throws
    /// `AudioValidationError.silent` only when *both* sources are silent or
    /// empty so the legacy "one participant didn't speak" case still
    /// succeeds with whatever audio is available.
    static func runDual(_ cfg: DualConfig) async throws -> [LabeledSegment] {
        async let micSegs = transcribeIfAudible(
            backend: cfg.backend,
            audioURL: cfg.micURL,
            model: cfg.model,
            language: cfg.language,
            onProgress: cfg.onMicProgress
        )
        async let sysSegs = transcribeIfAudible(
            backend: cfg.backend,
            audioURL: cfg.sysURL,
            model: cfg.model,
            language: cfg.language,
            onProgress: cfg.onSysProgress
        )
        let mic = try await micSegs
        let sys = try await sysSegs
        if (mic?.isEmpty ?? true) && (sys?.isEmpty ?? true) {
            throw AudioValidationError.silent(
                url: cfg.micURL ?? cfg.sysURL ?? URL(fileURLWithPath: "/"),
                probeSeconds: 0
            )
        }
        let coreLabeled = DualSourceTranscriber.mergeAndTag(
            micSegments: mic,
            sysSegments: sys,
            timing: cfg.timing,
            selfLabel: cfg.selfLabel,
            otherLabel: cfg.otherLabel
        )
        return coreLabeled.map { seg in
            LabeledSegment(
                start: seg.start,
                end: seg.end,
                speaker: seg.speaker,
                text: seg.text
            )
        }
    }

    /// Single-file legacy path: tag every segment with the generic "Speaker"
    /// label since cloud APIs don't return diarization on a mixed stream.
    static func runMixed(
        backend: TranscriptionBackend,
        audioURL: URL,
        model: String,
        language: String,
        onProgress: @escaping @Sendable (CloudProgressTracker.Snapshot) -> Void
    ) async throws -> [LabeledSegment] {
        try AudioValidation.ensureAudibleSignal(at: audioURL)
        let segs = try await CloudTranscriptionService.transcribe(
            backend: backend,
            audioURL: audioURL,
            model: model,
            language: language,
            onProgress: onProgress
        )
        return segs.map { seg in
            LabeledSegment(
                start: seg.start,
                end: seg.end,
                speaker: "Speaker",
                text: seg.text
            )
        }
    }

    private static func transcribeIfAudible(
        backend: TranscriptionBackend,
        audioURL: URL?,
        model: String,
        language: String,
        onProgress: @escaping @Sendable (CloudProgressTracker.Snapshot) -> Void
    ) async throws -> [TranscribeerCore.TranscriptSegment]? {
        guard let audioURL else { return nil }
        try Task.checkCancellation()
        do {
            try AudioValidation.ensureAudibleSignal(at: audioURL)
        } catch {
            return nil
        }
        return try await CloudTranscriptionService.transcribe(
            backend: backend,
            audioURL: audioURL,
            model: model,
            language: language,
            onProgress: onProgress
        )
    }
}
