import Foundation
import SpeakerKit
import WhisperKit

/// A speaker-labeled time segment.
public struct DiarSegment: Sendable {
    public let start: Double
    public let end: Double
    public let speaker: String

    public init(start: Double, end: Double, speaker: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// Speaker diarization via SpeakerKit (Pyannote backend).
public enum DiarizationService {
    /// Diarize an audio file into speaker-labeled segments.
    ///
    /// - Parameters:
    ///   - audioURL: Path to the audio file.
    ///   - numSpeakers: Expected speaker count, or nil for auto-detection.
    /// - Returns: Speaker segments sorted by start time, or empty on failure.
    public static func diarize(
        audioURL: URL,
        numSpeakers: Int? = nil
    ) async throws -> [DiarSegment] {
        let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)

        guard !audioArray.isEmpty else { return [] }

        let config = PyannoteConfig(
            download: true,
            load: true,
            verbose: false,
            logLevel: .none
        )

        let kit = try await SpeakerKit(config)

        let options = PyannoteDiarizationOptions(numberOfSpeakers: numSpeakers)

        let result = try await kit.diarize(audioArray: audioArray, options: options)

        return result.segments.map { seg in
            DiarSegment(
                start: Double(seg.startTime),
                end: Double(seg.endTime),
                speaker: speakerLabel(seg.speaker)
            )
        }
    }

    private static func speakerLabel(_ info: SpeakerInfo) -> String {
        if let id = info.speakerId {
            return "Speaker \(id)"
        }
        return "Unknown"
    }
}
