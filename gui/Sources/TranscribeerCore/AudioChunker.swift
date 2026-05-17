import AVFoundation
import Foundation

/// Splits an audio file (WAV, CAF, M4A — anything `AVAudioFile` can read) into
/// fixed-duration mono chunks. Output format is selectable:
///
///   - `.wavInt16` (default): RIFF PCM 16-bit. Fast for downstream
///     consumers like WhisperKit that decode WAV natively.
///   - `.aacM4A(bitrate:)`: AAC-LC in an MP4/M4A container. 5–10× smaller
///     than `.wavInt16` for speech — used by the cloud-transcription path
///     to keep upload payloads well under OpenAI's 25 MB request cap.
public enum AudioChunker {
    /// Minimum duration (seconds) for an emitted chunk. OpenAI's audio API
    /// rejects clips shorter than 0.1 s with HTTP 400 `audio_too_short`; we
    /// keep a 10× margin so a fractional tail at the end of a recording
    /// can't trip that limit. Tails shorter than this get folded into the
    /// previous chunk; an entire source shorter than this is skipped.
    static let minChunkSeconds: Double = 1.0
    public struct Chunk {
        /// URL of the chunk file on disk. Extension matches `OutputFormat`.
        public let url: URL
        /// Start time of this chunk within the original file, in seconds.
        public let startOffset: Double
    }

    /// Container/codec the chunker writes for each slice.
    public enum OutputFormat: Sendable, Equatable {
        /// Linear PCM 16-bit mono in a RIFF WAV container. Sample rate is
        /// taken from `targetSampleRate` if set, otherwise the source rate.
        case wavInt16
        /// AAC-LC mono in an MP4/M4A container at the given bitrate (bps).
        /// Use this for cloud uploads where wire-size matters.
        case aacM4A(bitrate: Int)

        var fileExtension: String {
            switch self {
            case .wavInt16: "wav"
            case .aacM4A: "m4a"
            }
        }
    }

    /// Playback duration in seconds for any format `AVAudioFile` can open.
    /// Returns `nil` on I/O failure or unreadable header (including truncated
    /// WAVs that never made it past the 44-byte header).
    public static func wavDuration(url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    /// Split `source` into chunks of `chunkDuration` seconds.
    ///
    /// Returns chunks in chronological order. Files are written to `tempDir`.
    /// Caller is responsible for deleting `tempDir` when done.
    ///
    /// - Parameters:
    ///   - source: Any `AVAudioFile`-readable audio file.
    ///   - chunkDuration: Length of each emitted chunk in seconds.
    ///   - targetSampleRate: When set, chunks are resampled via
    ///     `AVAudioConverter` to this rate before being written. Used by
    ///     the cloud-transcription path to stay under OpenAI's 25 MB
    ///     request cap — a 10-min mono Int16 WAV is ~58 MB at 48 kHz but
    ///     ~19 MB at 16 kHz. When `nil`, chunks are emitted at the source
    ///     rate and resampling is left to the downstream consumer
    ///     (WhisperKit resamples internally anyway).
    ///   - outputFormat: Container/codec for the emitted chunks. Defaults
    ///     to `.wavInt16` so local transcription paths keep their existing
    ///     fast WAV ingest. Cloud uploaders should pass `.aacM4A(...)` to
    ///     shrink each chunk by ~5×.
    ///   - tempDir: Output directory for the generated chunk files.
    public static func split(
        source: URL,
        chunkDuration: Double = 600,
        targetSampleRate: Double? = nil,
        outputFormat: OutputFormat = .wavInt16,
        tempDir: URL
    ) throws -> [Chunk] {
        let file = try AVAudioFile(forReading: source)
        let sourceFormat = file.processingFormat
        let sourceRate = sourceFormat.sampleRate
        guard sourceRate > 0, file.length > 0 else { return [] }

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let framesPerChunk = AVAudioFrameCount(max(1, Int64(chunkDuration * sourceRate)))
        let minTailFrames = Int64((minChunkSeconds * sourceRate).rounded(.up))
        // Reserve room for the tail-fold: the last chunk can grow by up to
        // `minChunkSeconds` worth of frames when we swallow a sub-minimum
        // remainder, so the read buffer must accommodate that overshoot.
        let bufferCapacity = framesPerChunk + AVAudioFrameCount(max(minTailFrames, 0))
        guard let readBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: bufferCapacity
        ) else {
            throw ChunkError.invalidWAV
        }

        let resampler = try makeResampler(
            from: sourceFormat,
            targetSampleRate: targetSampleRate,
            outputFormat: outputFormat
        )
        let outputRate = resampler?.outputFormat.sampleRate ?? sourceRate
        var chunks: [Chunk] = []
        var chunkIndex = 0
        var startFrame: AVAudioFramePosition = 0

        while startFrame < file.length {
            file.framePosition = startFrame
            let remaining = file.length - startFrame
            var toRead = AVAudioFrameCount(min(Int64(framesPerChunk), remaining))

            // Tail look-ahead: if the next iteration would emit a chunk
            // shorter than `minChunkSeconds`, fold the tail into this read
            // instead. Means the last chunk may run up to `minChunkSeconds`
            // longer than `chunkDuration`, but is never below the API floor.
            let tailAfter = remaining - Int64(toRead)
            if tailAfter > 0, tailAfter < minTailFrames {
                toRead = AVAudioFrameCount(remaining)
            }

            readBuffer.frameLength = 0
            try file.read(into: readBuffer, frameCount: toRead)
            guard readBuffer.frameLength > 0 else { break }

            // Drop pathologically short chunks (entire source < 1 s, or a
            // truncated trailing read). With no previous chunk to merge
            // into, sending the slice would only earn an `audio_too_short`
            // 400 from the API.
            let chunkSeconds = Double(readBuffer.frameLength) / sourceRate
            guard chunkSeconds >= minChunkSeconds else {
                startFrame += AVAudioFramePosition(readBuffer.frameLength)
                chunkIndex += 1
                continue
            }

            let chunkURL = tempDir.appendingPathComponent(
                "chunk-\(chunkIndex).\(outputFormat.fileExtension)"
            )
            try writeChunk(
                readBuffer: readBuffer,
                resampler: resampler,
                outputFormat: outputFormat,
                sampleRate: outputRate,
                to: chunkURL
            )
            chunks.append(Chunk(
                url: chunkURL,
                startOffset: Double(startFrame) / sourceRate
            ))

            startFrame += AVAudioFramePosition(readBuffer.frameLength)
            chunkIndex += 1
        }

        return chunks
    }

    /// `AVAudioConverter` + its target format, bundled together so the chunk
    /// loop doesn't have to thread two related values separately.
    private struct Resampler {
        let converter: AVAudioConverter
        let outputFormat: AVAudioFormat
    }

    /// Build a resampler when one is needed:
    ///  - AAC output always needs one (chunks must be mono Float32 at the
    ///    target rate before being fed to the AAC encoder).
    ///  - WAV output skips it when `targetSampleRate` matches the source
    ///    so we keep the fast "downmix straight to Int16" path intact.
    private static func makeResampler(
        from sourceFormat: AVAudioFormat,
        targetSampleRate: Double?,
        outputFormat: OutputFormat
    ) throws -> Resampler? {
        let effectiveTarget: Double
        switch outputFormat {
        case .wavInt16:
            guard let targetSampleRate,
                  abs(targetSampleRate - sourceFormat.sampleRate) > 0.5 else {
                return nil
            }
            effectiveTarget = targetSampleRate
        case .aacM4A:
            effectiveTarget = targetSampleRate ?? sourceFormat.sampleRate
        }
        guard let outputFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: effectiveTarget,
            channels: 1,
            interleaved: false
        ) else { throw ChunkError.invalidWAV }
        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFmt) else {
            throw ChunkError.invalidWAV
        }
        return Resampler(converter: converter, outputFormat: outputFmt)
    }

    /// Dispatch by output format: WAV gets the Int16 + custom-header path,
    /// AAC goes through `AVAudioFile`'s built-in encoder.
    private static func writeChunk(
        readBuffer: AVAudioPCMBuffer,
        resampler: Resampler?,
        outputFormat: OutputFormat,
        sampleRate: Double,
        to url: URL
    ) throws {
        switch outputFormat {
        case .wavInt16:
            let pcm = try encodeWAVData(readBuffer: readBuffer, resampler: resampler)
            try writeWAV(
                pcm: pcm,
                to: url,
                sampleRate: UInt32(sampleRate),
                numChannels: 1,
                bitsPerSample: 16
            )
        case let .aacM4A(bitrate):
            // AAC always has a resampler (see `makeResampler`).
            guard let resampler else { throw ChunkError.invalidWAV }
            let converted = try resample(buffer: readBuffer, with: resampler)
            try writeAAC(
                buffer: converted,
                to: url,
                sampleRate: sampleRate,
                bitrate: bitrate
            )
        }
    }

    /// Produce the Int16 PCM bytes for a single chunk: either a direct
    /// downmix at source rate, or run through `AVAudioConverter` first
    /// when the caller asked for a different rate.
    private static func encodeWAVData(
        readBuffer: AVAudioPCMBuffer,
        resampler: Resampler?
    ) throws -> Data {
        guard let resampler else { return pcmMonoInt16(from: readBuffer) }
        let converted = try resample(buffer: readBuffer, with: resampler)
        return float32MonoToInt16(buffer: converted)
    }

    /// Run the resampler's converter over `buffer`, returning a freshly
    /// allocated `AVAudioPCMBuffer` in the resampler's output format.
    /// Feeds the input in one shot, then signals end-of-stream so the
    /// converter can flush any tail samples.
    ///
    /// `AVAudioConverter` is stateful: once we signal `.endOfStream`, the
    /// instance is "done" and subsequent `convert(to:)` calls yield ~0
    /// frames. The chunk loop reuses one converter across every chunk, so
    /// we must `reset()` at the top of each call to clear that terminal
    /// state — otherwise only chunk[0] gets full-length output and every
    /// later chunk decodes to a fraction of a second (OpenAI then rejects
    /// with HTTP 400 `audio_too_short`).
    private static func resample(
        buffer: AVAudioPCMBuffer,
        with resampler: Resampler
    ) throws -> AVAudioPCMBuffer {
        let ratio = resampler.outputFormat.sampleRate / buffer.format.sampleRate
        let outFrames = AVAudioFrameCount(
            (Double(buffer.frameLength) * ratio).rounded(.up)
        )
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: resampler.outputFormat,
            frameCapacity: max(outFrames, 1)
        ) else { throw ChunkError.invalidWAV }

        resampler.converter.reset()
        var didProvide = false
        var convertError: NSError?
        let status = resampler.converter.convert(
            to: outBuffer,
            error: &convertError
        ) { _, statusOut in
            if didProvide {
                statusOut.pointee = .endOfStream
                return nil
            }
            didProvide = true
            statusOut.pointee = .haveData
            return buffer
        }
        if status == .error || convertError != nil { throw ChunkError.invalidWAV }
        return outBuffer
    }

    /// Write a Float32 mono buffer as an AAC-LC encoded MP4/M4A file.
    /// AVAudioFile transparently handles the encode through Core Audio;
    /// we just need to declare the codec via `settings`.
    private static func writeAAC(
        buffer: AVAudioPCMBuffer,
        to url: URL,
        sampleRate: Double,
        bitrate: Int
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitrate,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }

    /// Pack a mono Float32 buffer (output of `AVAudioConverter`) into Int16
    /// PCM bytes. Separate from `pcmMonoInt16` because that helper also
    /// downmixes multi-channel input; here the converter has already done
    /// that for us.
    private static func float32MonoToInt16(buffer: AVAudioPCMBuffer) -> Data {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return Data() }
        var samples = [Int16](repeating: 0, count: frames)
        let src = channels[0]
        for i in 0..<frames {
            samples[i] = floatToInt16(src[i])
        }
        return samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return Data() }
            return Data(bytes: base, count: frames * MemoryLayout<Int16>.size)
        }
    }

    // MARK: - Private

    /// Downmix an N-channel float PCM buffer to mono Int16 PCM bytes.
    ///
    /// Works for both interleaved and deinterleaved buffers; falls back to a
    /// zero-filled buffer only if `AVAudioPCMBuffer` didn't expose channel
    /// data (e.g. a zero-length read).
    private static func pcmMonoInt16(from buffer: AVAudioPCMBuffer) -> Data {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return Data() }
        var samples = [Int16](repeating: 0, count: frames)
        let channelCount = Int(buffer.format.channelCount)

        if let channels = buffer.floatChannelData {
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += channels[ch][i]
                }
                samples[i] = floatToInt16(sum / Float(max(channelCount, 1)))
            }
        } else if let interleaved = buffer.int16ChannelData {
            let src = interleaved[0]
            for i in 0..<frames {
                var sum: Int32 = 0
                for ch in 0..<channelCount {
                    sum += Int32(src[i * channelCount + ch])
                }
                samples[i] = Int16(clamping: sum / Int32(max(channelCount, 1)))
            }
        }

        return samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return Data() }
            return Data(bytes: base, count: frames * MemoryLayout<Int16>.size)
        }
    }

    private static func floatToInt16(_ value: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, value))
        let scaled = clamped * Float(Int16.max)
        return Int16(scaled.rounded())
    }

    private static func writeWAV(
        pcm: Data,
        to url: URL,
        sampleRate: UInt32,
        numChannels: UInt16,
        bitsPerSample: UInt16
    ) throws {
        let dataSize   = UInt32(pcm.count)
        let byteRate   = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign = UInt16(Int(numChannels) * Int(bitsPerSample) / 8)

        var h = Data(count: 44)
        h[0...3]   = Data([0x52, 0x49, 0x46, 0x46])
        h.writeUInt32LE(36 + dataSize, at: 4)
        h[8...11]  = Data([0x57, 0x41, 0x56, 0x45])
        h[12...15] = Data([0x66, 0x6d, 0x74, 0x20])
        h.writeUInt32LE(16, at: 16)
        h.writeUInt16LE(1, at: 20)
        h.writeUInt16LE(numChannels, at: 22)
        h.writeUInt32LE(sampleRate, at: 24)
        h.writeUInt32LE(byteRate, at: 28)
        h.writeUInt16LE(blockAlign, at: 32)
        h.writeUInt16LE(bitsPerSample, at: 34)
        h[36...39] = Data([0x64, 0x61, 0x74, 0x61])
        h.writeUInt32LE(dataSize, at: 40)

        var file = h
        file.append(pcm)
        try file.write(to: url)
    }
}

public enum ChunkError: Error {
    case invalidWAV
}

// MARK: - Data write helpers

private extension Data {
    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { replaceSubrange(offset..<(offset + 2), with: $0) }
    }
}
