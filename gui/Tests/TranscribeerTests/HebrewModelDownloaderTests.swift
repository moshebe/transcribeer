import Foundation
import Testing
@testable import TranscribeerApp
import TranscribeerCore

// MARK: - Helpers

/// Creates a minimal ModelManifestEntry for testing.
private func makeEntry(
    id: String = "test-model",
    sha256: String = "__PENDING__",
    url: URL? = nil,
    folderName: String = "test-model"
) -> ModelManifestEntry {
    ModelManifestEntry(
        id: id,
        displayName: "Test Model",
        sizeBytes: 1024,
        sha256: sha256,
        downloadURL: url ?? URL(string: "https://example.com/test.tar.zst")!,
        extractedFolderName: folderName
    )
}

/// Creates the three required .mlmodelc directories inside `folder`.
private func createRequiredBundles(in folder: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
        try fm.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
    }
}

/// Writes a minimal real tar.zst archive containing `folderName/<file>`.
private func makeFakeTarball(in dir: URL, folderName: String) throws -> URL {
    let fm = FileManager.default
    let sourceDir = dir.appendingPathComponent("source", isDirectory: true)
    let modelDir = sourceDir.appendingPathComponent(folderName, isDirectory: true)
    try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
    for bundle in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"] {
        try fm.createDirectory(at: modelDir.appendingPathComponent(bundle), withIntermediateDirectories: true)
        // Write a marker file so the dir isn't empty
        let marker = modelDir.appendingPathComponent(bundle).appendingPathComponent("model.espresso.shape")
        try Data("test".utf8).write(to: marker)
    }

    let tarball = dir.appendingPathComponent("\(folderName).tar.zst")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = ["--zstd", "-cf", tarball.path, "-C", sourceDir.path, folderName]
    try process.run()
    process.waitUntilExit()
    return tarball
}

// MARK: - Mock URLProtocol helpers

/// URLProtocol that serves a file at a registered path for download tasks.
/// For download tasks the system provides the file via `didFinishDownloadingTo`;
/// we simulate this by finishing the data load so the task writes it to disk.
private final class FileServingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var fileURL: URL?

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fileURL = Self.fileURL,
              let data = try? Data(contentsOf: fileURL),
              let requestURL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        guard let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "\(data.count)"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// URLProtocol that always fails with a network error.
private final class FailingURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
    }

    override func stopLoading() {}
}

private func makeMockSession(servingFile fileURL: URL) -> URLSession {
    FileServingURLProtocol.fileURL = fileURL
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [FileServingURLProtocol.self]
    return URLSession(configuration: cfg)
}

private func makeFailingSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [FailingURLProtocol.self]
    return URLSession(configuration: cfg)
}

// MARK: - Tests

@Suite("HebrewModelDownloader")
struct HebrewModelDownloaderTests {
    // MARK: isInstalled

    @Test("isInstalled returns false when folder is missing")
    @MainActor
    func isInstalledMissingFolder() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let downloader = HebrewModelDownloader(modelsBaseDir: tmpDir)
        let entry = makeEntry()
        #expect(!downloader.isInstalled(entry))
    }

    @Test("isInstalled returns false when folder exists but bundles are absent")
    @MainActor
    func isInstalledFolderWithoutBundles() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let folderName = "test-model"
        let modelFolder = tmpDir.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)

        let downloader = HebrewModelDownloader(modelsBaseDir: tmpDir)
        let entry = makeEntry(folderName: folderName)
        #expect(!downloader.isInstalled(entry))
    }

    @Test("isInstalled returns true when all three .mlmodelc dirs are present")
    @MainActor
    func isInstalledWithAllBundles() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let folderName = "test-model"
        let modelFolder = tmpDir.appendingPathComponent(folderName)
        try createRequiredBundles(in: modelFolder)

        let downloader = HebrewModelDownloader(modelsBaseDir: tmpDir)
        let entry = makeEntry(folderName: folderName)
        #expect(downloader.isInstalled(entry))
    }

    @Test("isInstalled returns false when only some bundles present")
    @MainActor
    func isInstalledPartialBundles() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let folderName = "partial-model"
        let modelFolder = tmpDir.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)
        // Only one of the three required bundles
        try FileManager.default.createDirectory(
            at: modelFolder.appendingPathComponent("AudioEncoder.mlmodelc"),
            withIntermediateDirectories: true
        )

        let downloader = HebrewModelDownloader(modelsBaseDir: tmpDir)
        let entry = makeEntry(folderName: folderName)
        #expect(!downloader.isInstalled(entry))
    }

    // MARK: download — already installed

    @Test("download is no-op when model is already installed")
    @MainActor
    func downloadNoOpWhenInstalled() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let folderName = "installed-model"
        try createRequiredBundles(in: tmpDir.appendingPathComponent(folderName))

        // Use a failing session — if download were attempted it would throw.
        let session = makeFailingSession()
        let downloader = HebrewModelDownloader(session: session, modelsBaseDir: tmpDir)
        let entry = makeEntry(folderName: folderName)

        // Should not throw; session is never used.
        try await downloader.download(entry)
        #expect(downloader.progress == 1.0 || downloader.progress == nil)
    }

    // MARK: SHA-256 verification

    @Test("download throws sha256Mismatch when digest does not match")
    @MainActor
    func downloadSHA256Mismatch() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write a tiny file that won't match any known sha256.
        let fakeFile = tmpDir.appendingPathComponent("fake.tar.zst")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try Data("not a real tarball".utf8).write(to: fakeFile)

        let session = makeMockSession(servingFile: fakeFile)
        let entry = makeEntry(
            sha256: "0000000000000000000000000000000000000000000000000000000000000000",
            folderName: "mismatch-model"
        )
        let modelsBaseDir = tmpDir.appendingPathComponent("cache")
        let downloader = HebrewModelDownloader(session: session, modelsBaseDir: modelsBaseDir)

        do {
            try await downloader.download(entry)
            Issue.record("Expected sha256Mismatch error but download succeeded")
        } catch let error as HebrewModelDownloadError {
            guard case .sha256Mismatch = error else {
                Issue.record("Expected sha256Mismatch, got \(error)")
                return
            }
        }

        // Tarball must not be left behind in modelsBaseDir
        let modelFolder = modelsBaseDir.appendingPathComponent("mismatch-model")
        #expect(!FileManager.default.fileExists(atPath: modelFolder.path))
    }

    @Test("download skips verification when sha256 is __PENDING__")
    @MainActor
    func downloadSkipsVerificationWhenPending() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let folderName = "pending-model"
        // Build a real tarball so extraction succeeds, then serve it via file:// URL
        let tarball = try makeFakeTarball(in: tmpDir, folderName: folderName)

        let modelsBaseDir = tmpDir.appendingPathComponent("cache")
        // Use default URLSession — file:// URLs work natively with downloadTask
        let entry = makeEntry(sha256: "__PENDING__", url: tarball, folderName: folderName)
        let downloader = HebrewModelDownloader(modelsBaseDir: modelsBaseDir)

        // Should succeed without throwing despite not knowing the real sha256
        try await downloader.download(entry)
        #expect(downloader.isInstalled(entry))
    }

    // MARK: Extraction and installation

    @Test("download extracts and installs model into modelsBaseDir")
    @MainActor
    func downloadExtractsToCorrectLocation() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let folderName = "real-model"
        // Build a real tarball and serve via file:// URL (no mock needed)
        let tarball = try makeFakeTarball(in: tmpDir, folderName: folderName)

        let modelsBaseDir = tmpDir.appendingPathComponent("cache")
        let entry = makeEntry(sha256: "__PENDING__", url: tarball, folderName: folderName)
        let downloader = HebrewModelDownloader(modelsBaseDir: modelsBaseDir)

        try await downloader.download(entry)

        let finalFolder = modelsBaseDir.appendingPathComponent(folderName)
        #expect(FileManager.default.fileExists(atPath: finalFolder.path))
        #expect(downloader.isInstalled(entry))
    }

    // MARK: Cancellation cleanup

    @Test("cancelled download leaves no orphaned files in modelsBaseDir")
    @MainActor
    func cancelledDownloadLeavesNoOrphanedFiles() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Stall the download indefinitely using a custom protocol that never delivers data
        final class StallingProtocol: URLProtocol, @unchecked Sendable {
            override static func canInit(with _: URLRequest) -> Bool { true }
            override static func canonicalRequest(for req: URLRequest) -> URLRequest { req }
            override func startLoading() { /* stall intentionally */ }
            override func stopLoading() {}
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StallingProtocol.self]
        let session = URLSession(configuration: cfg)

        let modelsBaseDir = tmpDir.appendingPathComponent("cache")
        let entry = makeEntry(folderName: "cancelled-model")
        let downloader = HebrewModelDownloader(session: session, modelsBaseDir: modelsBaseDir)

        let downloadTask = Task {
            try await downloader.download(entry)
        }

        // Give the download a moment to start then cancel it
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        downloadTask.cancel()

        // Wait for task to settle
        _ = try? await downloadTask.value

        // modelsBaseDir should either not exist or be empty
        let fm = FileManager.default
        if fm.fileExists(atPath: modelsBaseDir.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: modelsBaseDir.path)) ?? []
            #expect(contents.isEmpty)
        }
        // The model should not be considered installed
        #expect(!downloader.isInstalled(entry))
    }
}
