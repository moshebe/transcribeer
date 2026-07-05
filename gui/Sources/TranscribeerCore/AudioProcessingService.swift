import Foundation

/// Coordinates multiple audio-processing backends with ordered fallback.
///
/// The default chain tries ffmpeg first for compatibility with existing local
/// installs, then falls back to the dependency-free AVFoundation backend.
public struct AudioProcessingService: Sendable {
    private let backends: [any AudioProcessingBackend]

    public init(configuredFFmpegPath: String = "") {
        self.init(backends: [
            FFmpegAudioProcessor(configuredPath: configuredFFmpegPath),
            NativeAudioProcessor(),
        ])
    }

    public init(backends: [any AudioProcessingBackend]) {
        self.backends = backends
    }

    /// Transcodes with the first available backend that succeeds.
    ///
    /// - Parameter request: Source and destination audio settings.
    /// - Returns: Backend-specific transcode result; `backendID` identifies
    ///   which backend performed the work.
    /// - Throws: `AudioProcessingError.allBackendsFailed` after every backend
    ///   is unavailable or fails to transcode.
    public func transcode(_ request: AudioTranscodeRequest) async throws -> AudioTranscodeResult {
        var failures: [AudioProcessingBackendFailure] = []
        for backend in backends {
            if let failure = await availabilityFailure(for: backend) {
                failures.append(failure)
                continue
            }
            do {
                return try await backend.transcode(request)
            } catch {
                failures.append(Self.failure(backendID: backend.backendID, error: error))
            }
        }
        throw AudioProcessingError.allBackendsFailed(failures)
    }

    private func availabilityFailure(
        for backend: any AudioProcessingBackend
    ) async -> AudioProcessingBackendFailure? {
        let availability = await backend.availability()
        guard !availability.isAvailable else { return nil }
        return Self.failure(for: availability)
    }

    private static func failure(
        for availability: AudioProcessingBackendAvailability
    ) -> AudioProcessingBackendFailure {
        let message = AudioProcessingError.backendUnavailable(availability).localizedDescription
        return AudioProcessingBackendFailure(backendID: availability.backendID, message: message)
    }

    private static func failure(backendID: String, error: Error) -> AudioProcessingBackendFailure {
        AudioProcessingBackendFailure(backendID: backendID, message: error.localizedDescription)
    }
}
