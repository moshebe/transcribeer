import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: "com.transcribeer", category: "AudioMixer")

public enum AudioMixerError: Error {
    case cannotOpenInput(URL)
    case cannotCreateOutput(URL)
    case resampleFailed
}

/// Reads two CAF sidecars, resamples to 48 kHz mono via `AVAudioConverter`,
/// timeline-aligns by prepending silence to the later-starting source, mixes
/// sample-by-sample, and writes an AAC M4A.
///
/// Streaming design: the mix is produced in 1-second chunks so peak RAM stays
/// bounded regardless of recording length. A 60-minute recording used to
/// materialize ~2 GB of intermediate buffers; this implementation caps at a
/// few MB.
public final class AudioMixer {
    public init() {}

    private static let chunkFrames: AVAudioFrameCount = 48_000

    // `AVAudioFormat` for float32 mono 48 kHz can't actually fail on
    // supported systems, but the force-unwrap violates project lint rules.
    // Guard with a precondition so a hypothetical failure surfaces loudly.
    private let targetFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ) else {
            preconditionFailure("Failed to construct mono 48 kHz target format")
        }
        return format
    }()

    /// Produce `audio.m4a` from `audio.mic.caf` + `audio.sys.caf`.
    ///
    /// Either side may be missing on disk — the mix proceeds with the
    /// surviving source. Both missing → no output file.
    public func mix(
        micURL: URL,
        sysURL: URL,
        timing: TimingMetadata,
        outputURL: URL
    ) throws {
        let (micSilence, sysSilence) = Self.leadingSilenceFrames(
            timing: timing,
            targetRate: targetFormat.sampleRate
        )

        // Sys gets the effective-rate retag when drift is significant; mic
        // has no equivalent signal because AVAudioEngine's mic stream is
        // sample-accurate. Passing `nil` skips the retag path.
        let micReader = ResampledFileReader(
            url: micURL,
            targetFormat: targetFormat,
            leadingSilenceFrames: micSilence,
            retagSampleRate: nil
        )
        let sysReader = ResampledFileReader(
            url: sysURL,
            targetFormat: targetFormat,
            leadingSilenceFrames: sysSilence,
            retagSampleRate: Self.effectiveRetagRate(timing: timing)
        )

        // Guard against the "both sources missing" case before creating an
        // output file we'd otherwise leave empty.
        guard !micReader.isExhausted || !sysReader.isExhausted else {
            logger.info("mix: both sources missing/empty, skipping")
            return
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)
        } catch {
            throw AudioMixerError.cannotCreateOutput(outputURL)
        }

        try streamMix(micReader: micReader, sysReader: sysReader, outputFile: outputFile)
    }

    // MARK: - Streaming mix

    private func streamMix(
        micReader: ResampledFileReader,
        sysReader: ResampledFileReader,
        outputFile: AVAudioFile
    ) throws {
        while true {
            let micChunk = micReader.read(frames: Self.chunkFrames)
            let sysChunk = sysReader.read(frames: Self.chunkFrames)
            if micChunk == nil && sysChunk == nil { break }

            let outFrames = max(
                micChunk?.frameLength ?? 0,
                sysChunk?.frameLength ?? 0
            )
            if outFrames == 0 { break }

            guard let outBuf = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outFrames
            ),
                  let dstData = outBuf.floatChannelData else {
                throw AudioMixerError.resampleFailed
            }
            outBuf.frameLength = outFrames

            mixChunk(mic: micChunk, sys: sysChunk, into: dstData[0], frames: Int(outFrames))

            try outputFile.write(from: outBuf)
        }
    }

    private func mixChunk(
        mic: AVAudioPCMBuffer?,
        sys: AVAudioPCMBuffer?,
        into dst: UnsafeMutablePointer<Float>,
        frames: Int
    ) {
        let micData = mic?.floatChannelData?[0]
        let sysData = sys?.floatChannelData?[0]
        let micCount = Int(mic?.frameLength ?? 0)
        let sysCount = Int(sys?.frameLength ?? 0)

        for i in 0..<frames {
            let micSample: Float = i < micCount ? (micData?[i] ?? 0) : 0
            let sysSample: Float = i < sysCount ? (sysData?[i] ?? 0) : 0
            dst[i] = max(-1, min(1, micSample + sysSample))
        }
    }

    // MARK: - Timing helpers

    /// Compute how many frames of silence each source needs prepended so
    /// that both timelines line up on a common wall-clock origin.
    private static func leadingSilenceFrames(
        timing: TimingMetadata,
        targetRate: Double
    ) -> (mic: Int, sys: Int) {
        guard let micStart = timing.micStartEpoch,
              let sysStart = timing.sysStartEpoch else {
            return (0, 0)
        }
        let delta = sysStart - micStart
        if abs(delta) < 0.001 { return (0, 0) }
        let padFrames = Int(round(abs(delta) * targetRate))
        guard padFrames > 0 else { return (0, 0) }
        return delta > 0 ? (mic: 0, sys: padFrames) : (mic: padFrames, sys: 0)
    }

    /// When the sys tap's declared and effective rates disagree by more than
    /// 1 kHz, retag the source buffer at the effective rate so the resampler
    /// fixes the drift. Smaller disagreements are within normal tolerance.
    private static func effectiveRetagRate(timing: TimingMetadata) -> Double? {
        guard timing.sysDeclaredSampleRate > 0,
              timing.sysEffectiveSampleRate > 0,
              abs(timing.sysDeclaredSampleRate - timing.sysEffectiveSampleRate) > 1000
        else { return nil }
        return timing.sysEffectiveSampleRate
    }
}

// MARK: - ResampledFileReader

/// Pull-based reader that presents one CAF file as a stream of target-format
/// chunks, with optional leading silence (for timeline alignment) and an
/// optional sample-rate retag (for process-tap drift).
///
/// Yields `nil` once the source is exhausted so the mix loop can terminate.
private final class ResampledFileReader {
    let outputFormat: AVAudioFormat

    private let file: AVAudioFile?
    private let converter: AVAudioConverter?
    private let readBuffer: AVAudioPCMBuffer?
    /// Sibling of `readBuffer` tagged at the effective rate when drift
    /// correction is active. Shares channel count and capacity with
    /// `readBuffer`; sample data is copied in on each refill.
    private let retaggedReadBuffer: AVAudioPCMBuffer?
    private var leadingSilenceRemaining: Int
    private var exhausted = false

    var isExhausted: Bool { exhausted && leadingSilenceRemaining == 0 }

    init(
        url: URL,
        targetFormat: AVAudioFormat,
        leadingSilenceFrames: Int,
        retagSampleRate: Double?
    ) {
        self.outputFormat = targetFormat
        self.leadingSilenceRemaining = leadingSilenceFrames

        guard FileManager.default.fileExists(atPath: url.path),
              let openedFile = try? AVAudioFile(forReading: url),
              openedFile.length > 0 else {
            self.file = nil
            self.converter = nil
            self.readBuffer = nil
            self.retaggedReadBuffer = nil
            self.exhausted = true
            return
        }

        let nativeFormat = openedFile.processingFormat
        let sourceFormat: AVAudioFormat
        if let retag = retagSampleRate,
           abs(nativeFormat.sampleRate - retag) > 1000,
           let retagged = AVAudioFormat(
               commonFormat: .pcmFormatFloat32,
               sampleRate: retag,
               channels: nativeFormat.channelCount,
               interleaved: false
           ) {
            sourceFormat = retagged
        } else {
            sourceFormat = nativeFormat
        }

        guard let conv = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            self.file = openedFile
            self.converter = nil
            self.readBuffer = nil
            self.retaggedReadBuffer = nil
            self.exhausted = true
            return
        }

        // Preallocate a ~1s-at-source-rate read buffer. Re-filled on each
        // converter callback; sized so one read serves several chunks when
        // upsampling and straddles chunks when downsampling.
        let readCapacity = AVAudioFrameCount(max(sourceFormat.sampleRate, 1))
        self.readBuffer = AVAudioPCMBuffer(
            pcmFormat: nativeFormat,
            frameCapacity: readCapacity
        )

        self.file = openedFile
        self.converter = conv

        // When a retag is active, the file's AVAudioFile always reports its
        // declared-but-wrong rate, so we read native-format frames and then
        // hand the converter a sibling buffer advertising the effective rate
        // (same channel count + capacity, data copied each refill).
        if sourceFormat.sampleRate != nativeFormat.sampleRate {
            self.retaggedReadBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: readCapacity
            )
        } else {
            self.retaggedReadBuffer = nil
        }
    }

    /// Produce up to `frames` of output at `outputFormat`, or `nil` once
    /// the stream is fully drained.
    func read(frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if let silenceChunk = emitLeadingSilence(frames: frames) {
            return silenceChunk
        }
        return pullResampled(frames: frames)
    }

    // MARK: - Private

    private func emitLeadingSilence(frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard leadingSilenceRemaining > 0 else { return nil }
        let emit = min(Int(frames), leadingSilenceRemaining)
        guard let buf = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(emit)
        ),
              let data = buf.floatChannelData else {
            exhausted = true
            return nil
        }
        buf.frameLength = AVAudioFrameCount(emit)
        memset(data[0], 0, emit * MemoryLayout<Float>.size)
        leadingSilenceRemaining -= emit
        return buf
    }

    private func pullResampled(frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        if exhausted { return nil }
        guard let file, let converter, let readBuffer else {
            exhausted = true
            return nil
        }
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames) else {
            exhausted = true
            return nil
        }

        var convError: NSError?
        let status = converter.convert(to: output, error: &convError) { [self] _, statusPtr in
            do {
                try file.read(into: readBuffer)
            } catch {
                logger.error("file read failed: \(error.localizedDescription, privacy: .public)")
                statusPtr.pointee = .endOfStream
                return nil
            }
            guard readBuffer.frameLength > 0 else {
                statusPtr.pointee = .endOfStream
                return nil
            }
            statusPtr.pointee = .haveData
            // If a retag is active, copy the native-format frames into the
            // retagged sibling and hand that to the converter. Otherwise use
            // the native buffer directly.
            if let retagged = retaggedReadBuffer,
               let srcData = readBuffer.floatChannelData,
               let dstData = retagged.floatChannelData {
                retagged.frameLength = readBuffer.frameLength
                let channels = Int(readBuffer.format.channelCount)
                let bytes = Int(readBuffer.frameLength) * MemoryLayout<Float>.size
                for ch in 0..<channels {
                    memcpy(dstData[ch], srcData[ch], bytes)
                }
                return retagged
            }
            return readBuffer
        }

        switch status {
        case .haveData:
            return output.frameLength > 0 ? output : nil
        case .inputRanDry, .endOfStream:
            if output.frameLength > 0 { return output }
            exhausted = true
            return nil
        case .error:
            if let err = convError {
                logger.error("converter error: \(err.localizedDescription, privacy: .public)")
            }
            exhausted = true
            return nil
        @unknown default:
            exhausted = true
            return nil
        }
    }
}
