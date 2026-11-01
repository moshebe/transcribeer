import CryptoKit
import Foundation
import Testing
@testable import TranscribeerApp
import TranscribeerCore

// MARK: - Helpers

/// Creates a minimal ModelManifestEntry for testing.
private func makeEntry(
    id: String = "test-model",
    sha256: String = "__PENDING__",
    folderName: String = "test-model"
) throws -> ModelManifestEntry {
    ModelManifestEntry(
        id: id,
        displayName: "Test Model",
        sizeBytes: 1024,
        sha256: sha256,
        downloadURL: try #require(URL(string: "https://download.invalid/model.tar.zst")),
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
    try #require(process.terminationStatus == 0)
    return tarball
}

// MARK: - Mock URLProtocol helpers

/// All test requests stay inside URLSession's protocol layer.
private final class DownloadURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let directory = request.value(forHTTPHeaderField: "X-Stall-Directory") {
            do {
                try Data().write(to: URL(fileURLWithPath: directory).appendingPathComponent("started"))
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
            return
        }
        guard let path = request.value(forHTTPHeaderField: "X-Fixture-Path"),
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(data.count)"]
            ) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        if let directory = request.value(forHTTPHeaderField: "X-Stall-Directory") {
            try? Data().write(to: URL(fileURLWithPath: directory).appendingPathComponent("cancelled"))
        }
    }
}

private func makeMockSession(servingFile: URL? = nil, stallDirectory: URL? = nil) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DownloadURLProtocol.self]
    var headers: [String: String] = [:]
    if let servingFile { headers["X-Fixture-Path"] = servingFile.path }
    if let stallDirectory { headers["X-Stall-Directory"] = stallDirectory.path }
    config.httpAdditionalHeaders = headers
    return URLSession(configuration: config)
}

private func waitForFile(_ url: URL) async throws {
    for _ in 0..<200 {
        if FileManager.default.fileExists(atPath: url.path) { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(FileManager.default.fileExists(atPath: url.path), "Expected callback marker: \(url.path)")
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
        let entry = try makeEntry()
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
        let entry = try makeEntry(folderName: folderName)
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
        let entry = try makeEntry(folderName: folderName)
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
        let entry = try makeEntry(folderName: folderName)
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
        let session = makeMockSession()
        defer { session.invalidateAndCancel() }
        let downloader = HebrewModelDownloader(session: session, modelsBaseDir: tmpDir)
        let entry = try makeEntry(folderName: folderName)

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
        defer { session.invalidateAndCancel() }
        let entry = try makeEntry(
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

        #expect(try FileManager.default.contentsOfDirectory(atPath: modelsBaseDir.path).isEmpty)
    }

    @Test("Download installs archive content with verified or pending checksums", arguments: [false, true])
    @MainActor
    func installsArchive(verifyChecksum: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tarball = try makeFakeTarball(in: directory, folderName: "installed-model")
        let data = try Data(contentsOf: tarball)
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let entry = try makeEntry(
            sha256: verifyChecksum ? checksum : "__PENDING__",
            folderName: "installed-model"
        )
        let cache = directory.appendingPathComponent("cache")
        let session = makeMockSession(servingFile: tarball)
        defer { session.invalidateAndCancel() }
        let downloader = HebrewModelDownloader(session: session, modelsBaseDir: cache)

        try await downloader.download(entry)

        let marker = cache.appendingPathComponent("installed-model/AudioEncoder.mlmodelc/model.espresso.shape")
        #expect(try Data(contentsOf: marker) == Data("test".utf8))
        #expect(downloader.isInstalled(entry))
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path) == ["installed-model"])
    }

    // MARK: Cancellation cleanup

    @Test("Cancellation stops the request and removes download staging files", .timeLimit(.minutes(1)))
    @MainActor
    func cancellationRemovesStagingFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache")
        let session = makeMockSession(stallDirectory: directory)
        defer { session.invalidateAndCancel() }
        let downloader = HebrewModelDownloader(session: session, modelsBaseDir: cache)
        let entry = try makeEntry(folderName: "cancelled-model")
        let task = Task { try await downloader.download(entry) }
        defer { task.cancel() }

        try await waitForFile(directory.appendingPathComponent("started"))
        let staging = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        try #require(staging.count == 1)
        #expect(FileManager.default.fileExists(atPath: staging[0].appendingPathComponent("extract").path))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        try await waitForFile(directory.appendingPathComponent("cancelled"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
        #expect(downloader.isInstalled(entry) == false)
    }
}
