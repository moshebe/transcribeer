import AVFoundation
import Foundation

/// Cheaply detect whether a recording contains any audible signal.
///
/// Used up-front in the transcribe pipeline to avoid spending several minutes
/// of WhisperKit CPU on a well-formed WAV of zero-valued samples — the common
/// failure mode when ScreenCaptureKit records with no audio playing through
/// the system speakers, or when the mic is muted mid-session.
public enum AudioValidation {
    /// Peak amplitude below this value (≈ -60 dBFS) is treated as silent. Sits
    /// just above digital dither / noise floor; permissive enough to accept
    /// whispered (~-50 dBFS) and distant-mic (~-40 dBFS) recordings.
    public static let defaultPeakThreshold: Float = 0.001

    /// Only probe the start of the file. 30 s is enough to detect the "capture
    /// never produced any signal" case without scanning multi-hour recordings.
    public static let defaultProbeSeconds: Double = 30.0

    /// Returns `true` iff the first `probeSeconds` of the file reach a peak
    /// absolute amplitude of at least `peakThreshold`.
    ///
    /// On unreadable files the check conservatively returns `true` so the
    /// downstream decoder can surface the real error.
    public static func hasAudibleSignal(
        at url: URL,
        peakThreshold: Float = defaultPeakThreshold,
        probeSeconds: Double = defaultProbeSeconds
    ) throws -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else {
            // Unreadable — let the real decoder surface the actual problem.
            return true
        }

        let sampleRate = file.processingFormat.sampleRate
        let requestedFrames = Int64(probeSeconds * sampleRate)
        let maxFrames = AVAudioFrameCount(min(requestedFrames, file.length))
        guard maxFrames > 0 else { return false }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: maxFrames
        ) else {
            // Can't allocate — conservative: let downstream handle.
            return true
        }

        try file.read(into: buffer, frameCount: maxFrames)
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
            return false
        }

        var peak: Float = 0
        let frames = Int(buffer.frameLength)
        for ch in 0..<Int(buffer.format.channelCount) {
            let samples = channels[ch]
            for i in 0..<frames {
                let absVal = abs(samples[i])
                if absVal > peak { peak = absVal }
            }
        }
        return peak >= peakThreshold
    }
}

/// Surface-level error type callers throw when `hasAudibleSignal` returns
/// `false` and they want to abort the pipeline with an actionable message.
public enum AudioValidationError: LocalizedError {
    case silent(URL)

    public var errorDescription: String? {
        switch self {
        case .silent(let url):
            return """
                Recording appears silent (no audible signal in first 30 seconds \
                of \(url.lastPathComponent)). Common causes:
                  • System-audio capture with nothing playing through speakers.
                  • 'Screen & System Audio Recording' permission revoked mid-session.
                  • Microphone input muted or wrong device selected.
                Play the file in a media player to confirm, then re-record.
                """
        }
    }
}
