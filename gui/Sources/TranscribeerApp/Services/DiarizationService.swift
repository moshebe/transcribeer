import Foundation
import SpeakerKit
import WhisperKit

/// A speaker-labeled time segment.
struct DiarSegment: Sendable {
    let start: Double
    let end: Double
    let speaker: String
}

/// Speaker diarization via SpeakerKit (Pyannote backend).
///
/// All work is dispatched to a detached task so the main actor stays free.
enum DiarizationService {
    /// Diarize an audio file into speaker-labeled segments.
    ///
    /// - Parameters:
    ///   - audioURL: Path to the audio file.
    ///   - numSpeakers: Expected speaker count, or nil for auto-detection.
    /// - Returns: Speaker segments sorted by start time, or empty on failure.
    static func diarize(
        audioURL: URL,
        numSpeakers: Int? = nil,
    ) async throws -> [DiarSegment] {
        let path = audioURL.path
        let task = Task.detached(priority: .userInitiated) { () throws -> [DiarSegment] in
            try Task.checkCancellation()
            let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
            guard !audioArray.isEmpty else { return [] }

            let config = PyannoteConfig(
                download: true,
                load: true,
                verbose: false,
                logLevel: .none,
            )
            let kit = try await SpeakerKit(config)
            try Task.checkCancellation()

            let options = PyannoteDiarizationOptions(numberOfSpeakers: numSpeakers)
            let result = try await kit.diarize(audioArray: audioArray, options: options)

            return result.segments.map { seg in
                DiarSegment(
                    start: Double(seg.startTime),
                    end: Double(seg.endTime),
                    speaker: speakerLabel(seg.speaker),
                )
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func speakerLabel(_ info: SpeakerInfo) -> String {
        info.speakerId.map { "Speaker \($0)" } ?? "Unknown"
    }
}
