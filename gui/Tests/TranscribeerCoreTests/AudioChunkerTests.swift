import Foundation
import Testing
@testable import TranscribeerCore

struct AudioChunkerTests {
    // MARK: - Helpers

    /// Build a minimal PCM WAV with the given number of distinguishable samples.
    private func makeWAV(sampleRate: UInt32 = 16000, samples: Int) -> Data {
        var pcm = Data()
        for index in 0..<samples {
            var sample = Int16(index % 20_000 - 10_000).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var h = Data(count: 44)
        func w32(_ off: Int, _ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { h.replaceSubrange(off..<(off + 4), with: $0) }
        }
        func w16(_ off: Int, _ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { h.replaceSubrange(off..<(off + 2), with: $0) }
        }
        h[0...3]   = Data([0x52, 0x49, 0x46, 0x46]) // RIFF
        w32(4, 36 + UInt32(pcm.count))
        h[8...11]  = Data([0x57, 0x41, 0x56, 0x45]) // WAVE
        h[12...15] = Data([0x66, 0x6d, 0x74, 0x20]) // fmt
        w32(16, 16)
        w16(20, 1)           // PCM
        w16(22, 1)           // mono
        w32(24, sampleRate)
        w32(28, sampleRate * 2) // ByteRate
        w16(32, 2)           // BlockAlign
        w16(34, 16)          // BitsPerSample
        h[36...39] = Data([0x64, 0x61, 0x74, 0x61]) // data
        w32(40, UInt32(pcm.count))
        return h + pcm
    }

    private func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    // MARK: - split

    @Test
    func splitShortFileProducesOneChunk() throws {
        let wav = makeWAV(sampleRate: 16000, samples: 32000) // 2 sec
        let src = try writeTemp(wav)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }
        let chunks = try AudioChunker.split(source: src, chunkDuration: 10, tempDir: tempDir)
        try #require(chunks.count == 1)
        #expect(chunks[0].startOffset == 0.0)
    }

    @Test
    func splitProducesCorrectChunkCount() throws {
        // 25 seconds → 3 chunks (10, 10, 5)
        let wav = makeWAV(sampleRate: 16000, samples: 25 * 16000)
        let src = try writeTemp(wav)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }
        let chunks = try AudioChunker.split(source: src, chunkDuration: 10, tempDir: tempDir)
        try #require(chunks.count == 3)
        #expect(abs(chunks[0].startOffset - 0.0) < 0.001)
        #expect(abs(chunks[1].startOffset - 10.0) < 0.001)
        #expect(abs(chunks[2].startOffset - 20.0) < 0.001)
    }

    @Test
    func chunkFilesAreValidWAV() throws {
        let wav = makeWAV(sampleRate: 16000, samples: 32000) // 2 sec
        let src = try writeTemp(wav)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }
        let chunks = try AudioChunker.split(source: src, chunkDuration: 1, tempDir: tempDir)
        try #require(chunks.count == 2)
        for chunk in chunks {
            #expect(FileManager.default.fileExists(atPath: chunk.url.path))
            let d = try Data(contentsOf: chunk.url)
            #expect(d[0...3] == Data([0x52, 0x49, 0x46, 0x46])) // RIFF
            let dur = try decodedAudioDuration(chunk.url)
            #expect(abs(dur - 1.0) < 0.01)
        }
    }

    @Test
    func splitPreservesTotalPCMData() throws {
        let sampleCount = 25 * 16000
        let wav = makeWAV(sampleRate: 16000, samples: sampleCount)
        let src = try writeTemp(wav)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }
        let chunks = try AudioChunker.split(source: src, chunkDuration: 10, tempDir: tempDir)
        var reconstructed = Data()
        for chunk in chunks {
            reconstructed.append(try Data(contentsOf: chunk.url).dropFirst(44))
        }
        #expect(reconstructed == wav.dropFirst(44))
    }
}
