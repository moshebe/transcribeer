import Foundation
import Testing
@testable import TranscribeerCore

struct SourceAudioFilesTests {
    @Test("Preferred source audio uses raw CAF before compressed M4A")
    func preferredURLRawFirst() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = SourceAudioFiles.rawURL(in: dir, source: .mic)
        let compressed = SourceAudioFiles.compressedURL(in: dir, source: .mic)
        try Data("raw".utf8).write(to: raw)
        try Data("compressed".utf8).write(to: compressed)

        #expect(SourceAudioFiles.preferredURL(in: dir, source: .mic) == raw)
    }

    @Test("Preferred source audio falls back to compressed M4A")
    func preferredURLCompressedFallback() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let compressed = SourceAudioFiles.compressedURL(in: dir, source: .sys)
        try Data("compressed".utf8).write(to: compressed)

        #expect(SourceAudioFiles.preferredURL(in: dir, source: .sys) == compressed)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribeer-source-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
