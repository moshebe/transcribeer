import Foundation
import Testing
import TranscribeerCore
@testable import TranscribeerApp

struct SourceSidecarCompressorTests {
    @Test("Compression writes source M4A through audio processing service")
    func compressionWritesCompressedSidecarThroughService() async throws {
        let session = try makeSidecarSession(files: ["audio.mic.caf": Data("mic-pcm".utf8)])
        defer { try? FileManager.default.removeItem(at: session) }
        let backend = SidecarBackendStub(
            backendID: "stub-encoder",
            outcome: .write(Data("mic-aac".utf8))
        )
        let service = AudioProcessingService(backends: [backend])

        let report = await SourceSidecarCompressor.compressSession(in: session, service: service)
        let raw = session.appendingPathComponent("audio.mic.caf")
        let compressed = session.appendingPathComponent("audio.mic.m4a")

        #expect(report.compressed == [
            SourceSidecarCompressor.FileReport(
                source: "mic",
                method: "stub-encoder",
                rawBytes: 7,
                compressedBytes: 7
            ),
        ])
        #expect(report.skipped == ["sys"])
        #expect(report.failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: raw.path))
        #expect(try Data(contentsOf: compressed) == Data("mic-aac".utf8))
        #expect(await backend.requests() == [
            AudioTranscodeRequest(inputURL: raw, outputURL: compressed),
        ])
    }

    @Test("Cleanup removes raw CAF only after matching compressed sidecar exists")
    func cleanupRemovesRawOnlyAfterSuccessfulCompression() async throws {
        let session = try makeSidecarSession(files: ["audio.mic.caf": Data("mic-pcm".utf8)])
        defer { try? FileManager.default.removeItem(at: session) }
        let backend = SidecarBackendStub(
            backendID: "stub-encoder",
            outcome: .write(Data("mic-aac".utf8))
        )
        let service = AudioProcessingService(backends: [backend])

        _ = await SourceSidecarCompressor.compressSession(in: session, service: service)
        let cleanup = SessionManager.removeCaptureAudioSidecars(in: session)

        #expect(cleanup.removedFiles == ["audio.mic.caf"])
        #expect(cleanup.bytesFreed == 7)
        #expect(!FileManager.default.fileExists(atPath: session.appendingPathComponent("audio.mic.caf").path))
        #expect(FileManager.default.fileExists(atPath: session.appendingPathComponent("audio.mic.m4a").path))
    }

    @Test("Failed compression leaves raw CAF for retry")
    func failedCompressionRetainsRawSidecar() async throws {
        let session = try makeSidecarSession(files: ["audio.sys.caf": Data("sys-pcm".utf8)])
        defer { try? FileManager.default.removeItem(at: session) }
        let backend = SidecarBackendStub(
            backendID: "stub-encoder",
            outcome: .fail(.exportFailed(backendID: "stub-encoder", message: "encode failed"))
        )
        let service = AudioProcessingService(backends: [backend])

        let report = await SourceSidecarCompressor.compressSession(in: session, service: service)
        let cleanup = SessionManager.removeCaptureAudioSidecars(in: session)

        #expect(report.compressed.isEmpty)
        #expect(report.skipped == ["mic"])
        #expect(report.failed.count == 1)
        #expect(report.failed.first?.contains("sys: All audio processing backends failed") == true)
        #expect(cleanup.removedFiles.isEmpty)
        #expect(cleanup.bytesFreed == 0)
        #expect(FileManager.default.fileExists(atPath: session.appendingPathComponent("audio.sys.caf").path))
        #expect(!FileManager.default.fileExists(atPath: session.appendingPathComponent("audio.sys.m4a").path))
    }

    @Test("Historical maintenance compresses stable sessions and removes raw CAFs")
    func historicalMaintenanceCompactsStableSidecars() async throws {
        let sessionsDir = try makeSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let session = try makeSession(
            named: "2026-06-17-1231",
            in: sessionsDir,
            files: [
                "audio.m4a": Data("mixed-aac".utf8),
                "audio.mic.caf": Data("mic-pcm".utf8),
            ]
        )
        let backend = SidecarBackendStub(
            backendID: "stub-encoder",
            outcome: .write(Data("mic-aac".utf8))
        )
        let service = AudioProcessingService(backends: [backend])
        let raw = session.appendingPathComponent("audio.mic.caf")
        let compressed = session.appendingPathComponent("audio.mic.m4a")

        let report = await SourceSidecarCompressor.maintainHistoricalSessions(
            in: sessionsDir,
            service: service
        )

        #expect(report.sessionsScanned == 1)
        #expect(report.sessionsWithRawSidecars == 1)
        #expect(report.compressedFiles == 1)
        #expect(report.removedFiles == 1)
        #expect(report.bytesFreed == 7)
        #expect(report.failed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: raw.path))
        #expect(try Data(contentsOf: compressed) == Data("mic-aac".utf8))
        let requests = await backend.requests()
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.inputURL.path.hasSuffix("2026-06-17-1231/audio.mic.caf"))
        #expect(request.outputURL.path.hasSuffix("2026-06-17-1231/audio.mic.m4a"))
    }

    @Test("Historical maintenance skips raw-only sessions")
    func historicalMaintenanceSkipsRawOnlySessions() async throws {
        let sessionsDir = try makeSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }
        let session = try makeSession(
            named: "recording-in-progress",
            in: sessionsDir,
            files: ["audio.mic.caf": Data("mic-pcm".utf8)]
        )
        let backend = SidecarBackendStub(
            backendID: "stub-encoder",
            outcome: .write(Data("mic-aac".utf8))
        )
        let service = AudioProcessingService(backends: [backend])
        let raw = session.appendingPathComponent("audio.mic.caf")

        let report = await SourceSidecarCompressor.maintainHistoricalSessions(
            in: sessionsDir,
            service: service
        )

        #expect(report.sessionsScanned == 1)
        #expect(report.sessionsWithRawSidecars == 1)
        #expect(report.compressedFiles == 0)
        #expect(report.removedFiles == 0)
        #expect(report.bytesFreed == 0)
        #expect(report.failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: raw.path))
        #expect(await backend.requests().isEmpty)
    }
}

private actor SidecarBackendStub: AudioProcessingBackend {
    nonisolated let backendID: String

    private let outcome: SidecarBackendOutcome
    private var seenRequests: [AudioTranscodeRequest] = []

    init(backendID: String, outcome: SidecarBackendOutcome) {
        self.backendID = backendID
        self.outcome = outcome
    }

    func availability() async -> AudioProcessingBackendAvailability {
        .available(backendID: backendID)
    }

    func transcode(_ request: AudioTranscodeRequest) async throws -> AudioTranscodeResult {
        seenRequests.append(request)
        switch outcome {
        case let .write(data):
            try data.write(to: request.outputURL)
            return AudioTranscodeResult(
                outputURL: request.outputURL,
                backendID: backendID,
                outputBytes: UInt64(data.count),
                inputBytes: sidecarTestFileSize(request.inputURL)
            )
        case let .fail(error):
            throw error
        }
    }

    func requests() -> [AudioTranscodeRequest] {
        seenRequests
    }
}

private enum SidecarBackendOutcome: Sendable {
    case write(Data)
    case fail(AudioProcessingError)
}

private func makeSidecarSession(files: [String: Data]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcribeer-sidecar-compressor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (filename, data) in files {
        try data.write(to: dir.appendingPathComponent(filename))
    }
    return dir
}

private func makeSessionsDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("transcribeer-sidecar-maintenance-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeSession(named name: String, in sessionsDir: URL, files: [String: Data]) throws -> URL {
    let session = sessionsDir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
    for (filename, data) in files {
        try data.write(to: session.appendingPathComponent(filename))
    }
    return session
}

private func sidecarTestFileSize(_ url: URL) -> UInt64 {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
        return 0
    }
    return switch attributes[.size] {
    case let size as UInt64: size
    case let size as NSNumber: size.uint64Value
    default: 0
    }
}
