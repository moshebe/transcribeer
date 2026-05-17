import AVFoundation
import Foundation
import Testing
@testable import TranscribeerCore

/// Regression coverage for the dual-capture crash: re-transcribing a session
/// recorded to `audio.mic.caf` used to SIGTRAP inside `AudioChunker.split`
/// because the reader treated the CAF header as WAV and overflowed a UInt16.
/// These tests drive `split` with real AVAudioFile-produced inputs (CAF +
/// M4A) to ensure the chunker stays format-agnostic.
struct AudioChunkerCAFTests {
    // MARK: - Helpers

    /// Write a silent Float32 mono CAF of `durationSeconds` at `sampleRate`.
    /// Matches the format `DualAudioRecorder` produces for `audio.mic.caf`.
    private static func writeSilentCAF(
        durationSeconds: Double,
        sampleRate: Double = 48_000,
        channels: AVAudioChannelCount = 1
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunker-\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(durationSeconds * sampleRate)
        ) else {
            throw ChunkError.invalidWAV
        }
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        return url
    }

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-\(UUID().uuidString)")
    }

    // MARK: - split(CAF)

    @Test("Splitting a short CAF produces one WAV chunk without crashing")
    func splitShortCAF() throws {
        let src = try Self.writeSilentCAF(durationSeconds: 2)
        let tempDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let chunks = try AudioChunker.split(
            source: src,
            chunkDuration: 10,
            tempDir: tempDir
        )
        #expect(chunks.count == 1)
        #expect(chunks[0].startOffset == 0.0)

        let header = try Data(contentsOf: chunks[0].url).prefix(4)
        #expect(header == Data([0x52, 0x49, 0x46, 0x46])) // RIFF

        // Chunks are AVAudioFile-readable → verifies they're valid WAVs.
        let decoded = try AVAudioFile(forReading: chunks[0].url)
        #expect(decoded.processingFormat.sampleRate == 48_000)
        #expect(decoded.processingFormat.channelCount == 1)
    }

    @Test("Splitting a longer CAF yields chunks in chronological order")
    func splitMultiChunkCAF() throws {
        let src = try Self.writeSilentCAF(durationSeconds: 25)
        let tempDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let chunks = try AudioChunker.split(
            source: src,
            chunkDuration: 10,
            tempDir: tempDir
        )
        #expect(chunks.count == 3)
        #expect(chunks[0].startOffset == 0.0)
        #expect(abs(chunks[1].startOffset - 10.0) < 0.001)
        #expect(abs(chunks[2].startOffset - 20.0) < 0.001)

        // Every chunk is a valid WAV that AVAudioFile can re-open.
        for chunk in chunks {
            let decoded = try AVAudioFile(forReading: chunk.url)
            #expect(decoded.length > 0)
        }
    }

    @Test("Stereo CAF input is downmixed to mono WAV chunks")
    func splitStereoCAF() throws {
        let src = try Self.writeSilentCAF(durationSeconds: 1, channels: 2)
        let tempDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let chunks = try AudioChunker.split(
            source: src,
            chunkDuration: 10,
            tempDir: tempDir
        )
        #expect(chunks.count == 1)
        let decoded = try AVAudioFile(forReading: chunks[0].url)
        #expect(decoded.processingFormat.channelCount == 1)
    }

    @Test("wavDuration accepts any AVAudioFile-readable source")
    func durationOfCAF() throws {
        let src = try Self.writeSilentCAF(durationSeconds: 3)
        defer { try? FileManager.default.removeItem(at: src) }
        let duration = try #require(AudioChunker.wavDuration(url: src))
        #expect(abs(duration - 3.0) < 0.01)
    }

    // MARK: - Resampling

    @Test("targetSampleRate downsamples 48 kHz CAF to 16 kHz WAV chunks")
    func splitDownsamplesTo16kHz() throws {
        // 2 s of 48 kHz mono → chunks should come out at 16 kHz mono Int16.
        // The duration must be preserved (within rounding) and the file
        // size should match the 16 kHz expectation, not the 48 kHz one.
        let src = try Self.writeSilentCAF(durationSeconds: 2)
        let tempDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let chunks = try AudioChunker.split(
            source: src,
            chunkDuration: 10,
            targetSampleRate: 16_000,
            tempDir: tempDir
        )
        let chunk = try #require(chunks.first)
        let decoded = try AVAudioFile(forReading: chunk.url)
        #expect(decoded.processingFormat.sampleRate == 16_000)
        #expect(decoded.processingFormat.channelCount == 1)
        let duration = try #require(AudioChunker.wavDuration(url: chunk.url))
        #expect(abs(duration - 2.0) < 0.05)

        // 2 s mono Int16 @ 16 kHz ≈ 64 KB; @ 48 kHz it would be ~192 KB.
        // Use a generous upper bound that still excludes the 48 kHz size.
        let bytes = try Data(contentsOf: chunk.url).count
        #expect(bytes < 100_000, "expected 16 kHz-sized chunk, got \(bytes) bytes")
    }

    @Test("targetSampleRate matching source rate is a no-op fast path")
    func splitNoResampleWhenRatesMatch() throws {
        let src = try Self.writeSilentCAF(durationSeconds: 1)
        let tempDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }
        let chunks = try AudioChunker.split(
            source: src,
            chunkDuration: 10,
            targetSampleRate: 48_000,
            tempDir: tempDir
        )
        let chunk = try #require(chunks.first)
        let decoded = try AVAudioFile(forReading: chunk.url)
        #expect(decoded.processingFormat.sampleRate == 48_000)
    }

    // MARK: - AAC / M4A output

    @Test("outputFormat .aacM4A writes M4A files with the ftyp magic and AAC encoding")
    func splitWritesM4A() throws {
        let src = try Self.writeSilentCAF(durationSeconds: 2)
        let tempDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let chunks = try AudioChunker.split(
            source: src,
            chunkDuration: 10,
            targetSampleRate: 16_000,
            outputFormat: .aacM4A(bitrate: 48_000),
            tempDir: tempDir
        )
        let chunk = try #require(chunks.first)

        // 1. File extension comes from the format enum.
        #expect(chunk.url.pathExtension == "m4a")

        // 2. MP4 "ftyp" box lives at bytes 4..8 of any well-formed M4A.
        let header = try Data(contentsOf: chunk.url).prefix(12)
        let ftypMagic = Data([0x66, 0x74, 0x79, 0x70]) // "ftyp"
        #expect(
            header.dropFirst(4).prefix(4) == ftypMagic,
            "expected ftyp box at bytes 4..8, got \(Array(header))"
        )

        // 3. AVAudioFile can re-open it and reports the target sample rate.
        let decoded = try AVAudioFile(forReading: chunk.url)
        #expect(decoded.processingFormat.sampleRate == 16_000)
        #expect(decoded.processingFormat.channelCount == 1)
        let duration = try #require(AudioChunker.wavDuration(url: chunk.url))
        #expect(abs(duration - 2.0) < 0.1)
    }

    @Test("AAC output is dramatically smaller than the equivalent WAV chunk")
    func aacIsSmallerThanWAV() throws {
        // 5 s @ 16 kHz mono Int16 WAV ≈ 160 KB; AAC @ 48 kbps mono ≈ 30 KB.
        // Assert the ratio is at least 3:1 so the test catches accidental
        // re-routing of the cloud path back to WAV.
        let src = try Self.writeSilentCAF(durationSeconds: 5)
        let tempDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let wav = try AudioChunker.split(
            source: src,
            chunkDuration: 10,
            targetSampleRate: 16_000,
            outputFormat: .wavInt16,
            tempDir: tempDir.appendingPathComponent("wav"),
        )
        let aac = try AudioChunker.split(
            source: src,
            chunkDuration: 10,
            targetSampleRate: 16_000,
            outputFormat: .aacM4A(bitrate: 48_000),
            tempDir: tempDir.appendingPathComponent("aac"),
        )
        let wavBytes = try Data(contentsOf: #require(wav.first).url).count
        let aacBytes = try Data(contentsOf: #require(aac.first).url).count
        #expect(
            aacBytes * 3 < wavBytes,
            "AAC (\(aacBytes) B) was not at least 3× smaller than WAV (\(wavBytes) B)"
        )
    }

    // MARK: - Tail handling

    @Test("a sub-second tail is folded into the previous chunk, not emitted standalone")
    func tailFoldsIntoPriorChunk() throws {
        // Source duration = chunkDuration + 0.3 s. Without fold, we'd get
        // [10 s, 0.3 s] and the 0.3 s chunk would trip OpenAI's 0.1 s floor.
        // With fold, we get a single 10.3 s chunk.
        let src = try Self.writeSilentCAF(durationSeconds: 10.3)
        let tempDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }
        let chunks = try AudioChunker.split(
            source: src,
            chunkDuration: 10,
            tempDir: tempDir
        )
        #expect(chunks.count == 1)
        let chunk = try #require(chunks.first)
        let duration = try #require(AudioChunker.wavDuration(url: chunk.url))
        #expect(abs(duration - 10.3) < 0.05)
    }

    @Test("a source shorter than the API minimum produces zero chunks")
    func subMinimumSourceYieldsNoChunks() throws {
        // 0.5 s is below `minChunkSeconds` (1 s) so the chunker must skip
        // the slice entirely. Caller treats the empty result as "silent".
        let src = try Self.writeSilentCAF(durationSeconds: 0.5)
        let tempDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }
        let chunks = try AudioChunker.split(
            source: src,
            chunkDuration: 10,
            tempDir: tempDir
        )
        #expect(chunks.isEmpty)
    }

    @Test("default outputFormat stays .wavInt16 so the local path is unchanged")
    func defaultOutputIsWAV() throws {
        let src = try Self.writeSilentCAF(durationSeconds: 1)
        let tempDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }
        let chunks = try AudioChunker.split(
            source: src,
            chunkDuration: 10,
            tempDir: tempDir
        )
        let chunk = try #require(chunks.first)
        #expect(chunk.url.pathExtension == "wav")
        let header = try Data(contentsOf: chunk.url).prefix(4)
        #expect(header == Data([0x52, 0x49, 0x46, 0x46])) // RIFF
    }
}
