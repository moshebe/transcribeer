import CryptoKit
import Darwin
import Foundation
import os
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
private func makeFakeTarball(in dir: URL, folderName: String, payloadBytes: Int = 0) throws -> URL {
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

    if payloadBytes > 0 {
        var payload = Data(count: payloadBytes)
        payload.withUnsafeMutableBytes { bytes in
            if let base = bytes.baseAddress { arc4random_buf(base, bytes.count) }
        }
        try payload.write(to: modelDir.appendingPathComponent("AudioEncoder.mlmodelc/weights"))
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
    private let transfer = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

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
            if let gate = request.value(forHTTPHeaderField: "X-Progress-Directory") {
                sendInChunks(data, gate: URL(fileURLWithPath: gate))
                return
            }
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        transfer.withLock { $0?.cancel() }
        if let directory = request.value(forHTTPHeaderField: "X-Stall-Directory") {
            try? Data().write(to: URL(fileURLWithPath: directory).appendingPathComponent("cancelled"))
        }
    }

    private func sendInChunks(_ data: Data, gate: URL) {
        let midpoint = data.count / 2
        client?.urlProtocol(self, didLoad: data.prefix(midpoint))
        transfer.withLock { task in
            task = Task {
                do {
                    for _ in 0..<500 {
                        try Task.checkCancellation()
                        if FileManager.default.fileExists(atPath: gate.appendingPathComponent("continue").path) {
                            client?.urlProtocol(self, didLoad: data.suffix(from: midpoint))
                            client?.urlProtocolDidFinishLoading(self)
                            return
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    throw URLError(.timedOut)
                } catch {
                    if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) }
                }
            }
        }
    }
}

private func makeMockSession(
    servingFile: URL? = nil, stallDirectory: URL? = nil, progressDirectory: URL? = nil
) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DownloadURLProtocol.self]
    var headers: [String: String] = [:]
    if let servingFile { headers["X-Fixture-Path"] = servingFile.path }
    if let stallDirectory { headers["X-Stall-Directory"] = stallDirectory.path }
    if let progressDirectory { headers["X-Progress-Directory"] = progressDirectory.path }
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

        #expect(try FileManager.default.contentsOfDirectory(atPath: modelsBaseDir.path)
            .allSatisfy { $0 == ".download.lock" })
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
        #expect(try !FileManager.default.contentsOfDirectory(atPath: cache.path)
            .contains { $0.hasPrefix(".download-") })
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
            .filter { $0.lastPathComponent.hasPrefix(".download-") }
        try #require(staging.count == 1)
        #expect(FileManager.default.fileExists(atPath: staging[0].appendingPathComponent("extract").path))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        try await waitForFile(directory.appendingPathComponent("cancelled"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path)
            .allSatisfy { $0 == ".download.lock" })
        #expect(downloader.isInstalled(entry) == false)
    }

    @Test("A partial transfer publishes progress before the model is installed", .timeLimit(.minutes(1)))
    @MainActor
    func progressDuringTransfer() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tarball = try makeFakeTarball(in: directory, folderName: "progress-model", payloadBytes: 1_048_576)
        let session = makeMockSession(servingFile: tarball, progressDirectory: directory)
        defer { session.invalidateAndCancel() }
        let downloader = HebrewModelDownloader(
            session: session, modelsBaseDir: directory.appendingPathComponent("cache")
        )
        let entry = try makeEntry(folderName: "progress-model")
        let task = Task { try await downloader.download(entry) }
        defer { task.cancel() }

        for _ in 0..<200 {
            if let progress = downloader.progress, progress > 0, progress < 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let progress = try #require(downloader.progress)
        #expect(progress > 0 && progress < 1)
        #expect(downloader.currentDownload?.id == entry.id)
        #expect(!downloader.isInstalled(entry))
        try Data().write(to: directory.appendingPathComponent("continue"))
        try await task.value

        #expect(downloader.isInstalled(entry))
        #expect(downloader.currentDownload == nil)
        #expect(downloader.progress == nil)
    }

    @Test("Cleanup removes abandoned staging but preserves an active download", .timeLimit(.minutes(1)))
    @MainActor
    func cleanupProtectsActiveDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tarball = try makeFakeTarball(in: directory, folderName: "recovered-model")
        let cache = directory.appendingPathComponent("cache")
        let abandoned = cache.appendingPathComponent(".download-abandoned/extract")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try Data("partial model".utf8).write(to: abandoned.appendingPathComponent("model"))
        let unrelated = cache.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        let stalledSession = makeMockSession(stallDirectory: directory)
        let readySession = makeMockSession(servingFile: tarball)
        defer { stalledSession.invalidateAndCancel(); readySession.invalidateAndCancel() }
        let active = HebrewModelDownloader(session: stalledSession, modelsBaseDir: cache)
        let next = HebrewModelDownloader(session: readySession, modelsBaseDir: cache)
        let entry = try makeEntry(folderName: "recovered-model")
        let task = Task { try await active.download(entry) }
        defer { task.cancel() }
        try await waitForFile(directory.appendingPathComponent("started"))
        #expect(!FileManager.default.fileExists(atPath: abandoned.deletingLastPathComponent().path))
        let activeFolder = try #require(FileManager.default.contentsOfDirectory(
            at: cache, includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix(".download-") })

        do {
            try await next.download(entry)
            Issue.record("A second downloader must not enter the active staging directory")
        } catch let error as HebrewModelDownloadError {
            guard case .downloadInProgress = error else { throw error }
        }
        #expect(FileManager.default.fileExists(atPath: activeFolder.appendingPathComponent("extract").path))
        #expect(try Data(contentsOf: unrelated) == Data("keep".utf8))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await next.download(entry)
        #expect(next.isInstalled(entry))
    }
}
