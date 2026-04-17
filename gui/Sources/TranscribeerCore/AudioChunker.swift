import Foundation

/// Splits a WAV audio file into fixed-duration chunk files.
/// Reads actual header fields so it works with any PCM WAV (not just 16kHz/mono/16-bit).
public enum AudioChunker {

    public struct Chunk {
        /// URL of the chunk WAV file on disk.
        public let url: URL
        /// Start time of this chunk within the original file, in seconds.
        public let startOffset: Double
    }

    /// Returns the playback duration in seconds of a WAV file, or nil if unreadable.
    public static func wavDuration(url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count >= 44 else { return nil }
        let dataBytes   = Double(data.readUInt32LE(at: 40))
        let sampleRate  = Double(data.readUInt32LE(at: 24))
        let numChannels = Double(data.readUInt16LE(at: 22))
        let bitsPerSample = Double(data.readUInt16LE(at: 34))
        let bytesPerSec = sampleRate * numChannels * bitsPerSample / 8
        guard bytesPerSec > 0 else { return nil }
        return dataBytes / bytesPerSec
    }

    /// Split `source` WAV into chunks of `chunkDuration` seconds.
    ///
    /// Returns chunks in chronological order. Files are written to `tempDir`.
    /// Caller is responsible for deleting `tempDir` when done.
    public static func split(
        source: URL,
        chunkDuration: Double = 600,
        tempDir: URL
    ) throws -> [Chunk] {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard data.count >= 44 else { throw ChunkError.invalidWAV }

        let sampleRate    = data.readUInt32LE(at: 24)
        let numChannels   = data.readUInt16LE(at: 22)
        let bitsPerSample = data.readUInt16LE(at: 34)
        let frameSize     = Int(numChannels) * Int(bitsPerSample / 8)
        let pcm           = data.subdata(in: 44..<data.count)

        guard frameSize > 0, pcm.count > 0 else { return [] }

        let samplesPerChunk = Int(Double(sampleRate) * chunkDuration)
        let bytesPerChunk   = samplesPerChunk * frameSize

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var chunks: [Chunk] = []
        var byteOffset = 0
        var chunkIndex = 0

        while byteOffset < pcm.count {
            let end      = min(byteOffset + bytesPerChunk, pcm.count)
            let chunkPCM = pcm.subdata(in: byteOffset..<end)
            let chunkURL = tempDir.appendingPathComponent("chunk-\(chunkIndex).wav")

            try writeWAV(
                pcm: chunkPCM,
                to: chunkURL,
                sampleRate: sampleRate,
                numChannels: numChannels,
                bitsPerSample: bitsPerSample
            )

            let startOffset = Double(byteOffset / frameSize) / Double(sampleRate)
            chunks.append(Chunk(url: chunkURL, startOffset: startOffset))

            byteOffset = end
            chunkIndex += 1
        }

        return chunks
    }

    // MARK: - Private

    private static func writeWAV(
        pcm: Data,
        to url: URL,
        sampleRate: UInt32,
        numChannels: UInt16,
        bitsPerSample: UInt16
    ) throws {
        let dataSize   = UInt32(pcm.count)
        let byteRate   = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign = numChannels * (bitsPerSample / 8)

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

// MARK: - Data read/write helpers

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { ptr in
            var v: UInt32 = 0
            memcpy(&v, ptr.baseAddress!.advanced(by: offset), 4)
            return UInt32(littleEndian: v)
        }
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return withUnsafeBytes { ptr in
            var v: UInt16 = 0
            memcpy(&v, ptr.baseAddress!.advanced(by: offset), 2)
            return UInt16(littleEndian: v)
        }
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { replaceSubrange(offset..<(offset+4), with: $0) }
    }

    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { replaceSubrange(offset..<(offset+2), with: $0) }
    }
}
