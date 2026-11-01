@preconcurrency import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: "com.transcribeer", category: "SourceTrackWriter")

/// Writes one capture source (mic or system audio) to a mono Float32 CAF
/// whose format is fixed by the first buffer.
///
/// Audio routes change mid-recording — AirPods connecting, or switching to
/// the hands-free profile when a call opens the mic — and the capture is
/// rebuilt with a new sample rate. `AVAudioFile` rejects buffers whose format
/// differs from the file's, so later buffers are converted to the file format
/// instead of being dropped.
///
/// Rebuilding the capture also leaves a hole in the stream. After
/// `markDiscontinuity()`, the next buffer is preceded by silence covering the
/// wall-clock gap, so the source stays aligned with the other one in the mix.
/// Padding only happens after an explicit discontinuity: normal delivery
/// jitter and device clock drift are left to `AudioMixer`.
final class SourceTrackWriter {
    private let url: URL
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?

    /// Wall-clock time of the first buffer.
    private(set) var anchor: Date?
    /// Sample rate of the CAF file, set by the first buffer.
    private(set) var fileSampleRate: Double = 0
    /// Frames written so far, including silence padding.
    private(set) var framesWritten: Int64 = 0
    /// Wall-clock time the last buffer arrived.
    private(set) var lastWriteDate: Date?

    private var pendingDiscontinuity = false

    /// Longest gap filled with silence. A longer one (e.g. the Mac slept)
    /// is capped so a bad clock reading can't write hours of silence.
    static let maxPaddingSeconds: Double = 30

    init(url: URL) {
        self.url = url
    }

    /// Note that the capture was rebuilt, so the next buffer follows a gap.
    func markDiscontinuity() {
        pendingDiscontinuity = true
    }

    /// Append `buffer`, received at `date`. Multi-channel input is downmixed.
    func write(_ buffer: AVAudioPCMBuffer, at date: Date) {
        guard buffer.frameLength > 0 else { return }
        let mono = buffer.format.channelCount > 1 ? (Self.downmixToMono(buffer) ?? buffer) : buffer

        if file == nil {
            open(format: mono.format, at: date)
        }
        guard let file, let output = convertToFileFormat(mono) else { return }

        if pendingDiscontinuity {
            pendingDiscontinuity = false
            padGap(before: output, arrivingAt: date, file: file)
        }

        do {
            try file.write(from: output)
            framesWritten += Int64(output.frameLength)
            lastWriteDate = date
        } catch {
            logger.error(
                "write failed file=\(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription)"
            )
        }
    }

    /// Release the file so it is flushed and closed.
    func close() {
        file = nil
        converter = nil
    }

    // MARK: - Private

    private func open(format: AVAudioFormat, at date: Date) {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            anchor = date
            fileSampleRate = format.sampleRate
        } catch {
            logger.error(
                "open failed file=\(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription)"
            )
        }
    }

    /// Insert silence for the time between the previous buffer and this one,
    /// minus this buffer's own duration (it arrives once fully captured).
    private func padGap(before buffer: AVAudioPCMBuffer, arrivingAt date: Date, file: AVAudioFile) {
        guard let lastWriteDate else { return }
        let bufferSeconds = Double(buffer.frameLength) / fileSampleRate
        let gap = date.timeIntervalSince(lastWriteDate) - bufferSeconds
        let seconds = min(gap, Self.maxPaddingSeconds)
        let frames = AVAudioFrameCount(max(0, seconds * fileSampleRate))
        guard frames > 0,
              let silence = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { return }
        // A fresh buffer's memory is not guaranteed to be zeroed.
        silence.frameLength = frames
        if let channel = silence.floatChannelData?[0] {
            channel.update(repeating: 0, count: Int(frames))
        }
        do {
            try file.write(from: silence)
            framesWritten += Int64(frames)
            logger.info(
                """
                padded gap file=\(self.url.lastPathComponent, privacy: .public) \
                seconds=\(seconds, privacy: .public)
                """
            )
        } catch {
            logger.error("pad failed: \(error.localizedDescription)")
        }
    }

    private func convertToFileFormat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let file else { return nil }
        let target = file.processingFormat
        if buffer.format == target { return buffer }

        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            logger.info(
                """
                format change file=\(self.url.lastPathComponent, privacy: .public) \
                from=\(buffer.format.sampleRate, privacy: .public) \
                to=\(target.sampleRate, privacy: .public)
                """
            )
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            logger.error("convert failed: \(conversionError?.localizedDescription ?? "unknown")")
            return nil
        }
        return output
    }

    static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ),
            let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
            let srcData = buffer.floatChannelData,
            let dstData = mono.floatChannelData
        else {
            return nil
        }
        mono.frameLength = buffer.frameLength

        let chCount = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        let dst = dstData[0]
        for frame in 0..<frames {
            var sum: Float = 0
            for ch in 0..<chCount {
                sum += srcData[ch][frame]
            }
            dst[frame] = sum / Float(chCount)
        }
        return mono
    }
}
