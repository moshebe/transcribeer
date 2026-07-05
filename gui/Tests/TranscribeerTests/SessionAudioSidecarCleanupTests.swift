import Foundation
import Testing
@testable import TranscribeerApp

struct SessionAudioSidecarCleanupTests {
    private static func makeSession(files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribeer-sidecar-cleanup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (filename, contents) in files {
            try Data(contents.utf8).write(to: dir.appendingPathComponent(filename))
        }
        return dir
    }

    @Test("Cleanup removes raw CAFs only when compressed source sidecars exist")
    func removesCaptureSidecarsWithCompressedReplacements() throws {
        let dir = try Self.makeSession(files: [
            "audio.m4a": "mixed",
            "audio.mic.caf": "mic-pcm",
            "audio.sys.caf": "sys-pcm",
            "audio.mic.m4a": "mic-aac",
            "audio.sys.m4a": "sys-aac",
            "timing.json": "{}",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let cleanup = SessionManager.removeCaptureAudioSidecars(in: dir)

        #expect(Set(cleanup.removedFiles) == Set(["audio.mic.caf", "audio.sys.caf"]))
        #expect(cleanup.bytesFreed == 14)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.mic.caf").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.sys.caf").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.mic.m4a").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.sys.m4a").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("timing.json").path))
    }

    @Test("Cleanup keeps CAFs when only mixed audio exists")
    func keepsSidecarsWithoutCompressedReplacements() throws {
        let dir = try Self.makeSession(files: [
            "audio.m4a": "mixed",
            "audio.mic.caf": "mic-pcm",
            "audio.sys.caf": "sys-pcm",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let cleanup = SessionManager.removeCaptureAudioSidecars(in: dir)

        #expect(cleanup.removedFiles.isEmpty)
        #expect(cleanup.bytesFreed == 0)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.mic.caf").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.sys.caf").path))
    }

    @Test("Cleanup removes only the source that has a compressed replacement")
    func removesSidecarsIndependently() throws {
        let dir = try Self.makeSession(files: [
            "audio.mic.caf": "mic-pcm",
            "audio.sys.caf": "sys-pcm",
            "audio.mic.m4a": "mic-aac",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let cleanup = SessionManager.removeCaptureAudioSidecars(in: dir)

        #expect(cleanup.removedFiles == ["audio.mic.caf"])
        #expect(cleanup.bytesFreed == 7)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.mic.caf").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.sys.caf").path))
    }
}
