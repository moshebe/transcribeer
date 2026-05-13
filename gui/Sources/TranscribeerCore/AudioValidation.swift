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
    /// Conservative fallback: any I/O or allocation failure returns `true` so
    /// the real decoder downstream can surface the actual format/permission
    /// error instead of having this guard masquerade as a silent-audio
    /// problem.
    public static func hasAudibleSignal(
        at url: URL,
        peakThreshold: Float = defaultPeakThreshold,
        probeSeconds: Double = defaultProbeSeconds
    ) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else {
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
            return true
        }

        do {
            try file.read(into: buffer, frameCount: maxFrames)
        } catch {
            return true
        }

        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
            return false
        }

        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var peak: Float = 0
        for ch in 0..<channelCount {
            let samples = channels[ch]
            for i in 0..<frames {
                let value = abs(samples[i])
                if value > peak { peak = value }
            }
        }
        return peak >= peakThreshold
    }

    /// Throws `AudioValidationError.silent` if `hasAudibleSignal` returns
    /// `false`. Convenience wrapper for pipeline callers that want to abort
    /// before loading WhisperKit. Keeps the probe-window reported in the
    /// error message in lock-step with the window actually probed.
    public static func ensureAudibleSignal(
        at url: URL,
        peakThreshold: Float = defaultPeakThreshold,
        probeSeconds: Double = defaultProbeSeconds
    ) throws {
        let audible = hasAudibleSignal(
            at: url,
            peakThreshold: peakThreshold,
            probeSeconds: probeSeconds
        )
        if !audible {
            throw AudioValidationError.silent(url: url, probeSeconds: probeSeconds)
        }
    }
}

/// Surface-level error type for pipeline callers that abort on a failed
/// audible-signal check.
public enum AudioValidationError: LocalizedError {
    case silent(url: URL, probeSeconds: Double)

    public var errorDescription: String? {
        switch self {
        case let .silent(url, probeSeconds):
            let seconds = Int(probeSeconds.rounded())
            return """
                Recording appears silent (no audible signal in first \(seconds) seconds \
                of \(url.lastPathComponent)). Common causes:
                  • System-audio capture with nothing playing through speakers.
                  • System Audio Recording permission revoked mid-session.
                  • Microphone input muted or wrong device selected.
                Play the file in a media player to confirm, then re-record.
                """
        }
    }
}
