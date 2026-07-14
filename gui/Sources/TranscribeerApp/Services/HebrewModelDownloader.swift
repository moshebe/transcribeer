import CryptoKit
import Foundation
import os
import TranscribeerCore
import ZstdExtractor

// MARK: - Error type

enum HebrewModelDownloadError: LocalizedError {
    case sha256Mismatch(expected: String, got: String)
    case extractionFailed(exitCode: Int32, stderr: String)
    case writeFailed(URL, underlying: Error)
    case network(underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .sha256Mismatch(expected, got):
            "SHA-256 mismatch — expected \(expected), got \(got). Download may be corrupt."
        case let .extractionFailed(code, stderr):
            "tar extraction failed (exit \(code)): \(stderr)"
        case let .writeFailed(url, underlying):
            "Failed to write \(url.lastPathComponent): \(underlying.localizedDescription)"
        case let .network(underlying):
            "Network error: \(underlying.localizedDescription)"
        }
    }
}

// MARK: - Progress throttle

/// Rate-limits progress callbacks so the main actor isn't flooded with updates.
/// Mirrors ProgressSink in TranscriptionService — minimum 1% delta.
private final class DownloadProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lastValue: Double = -1
    private static let threshold: Double = 0.01
    private let emit: @MainActor @Sendable (Double) -> Void

    init(emit: @escaping @MainActor @Sendable (Double) -> Void) {
        self.emit = emit
    }

    func submit(_ value: Double) {
        let shouldEmit = lock.withLock {
            let crossed = value == 1.0 || value == 0.0 || value - lastValue >= Self.threshold
            if crossed { lastValue = value }
            return crossed
        }
        guard shouldEmit else { return }
        let e = emit
        let v = value
        Task { @MainActor in e(v) }
    }
}

// MARK: - URLSession delegate

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progressSink: DownloadProgressSink
    // Continuation is set once before the task starts; written from one thread, read from another.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(progressSink: DownloadProgressSink) {
        self.progressSink = progressSink
    }

    func setContinuation(_ continuation: CheckedContinuation<URL, Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Move file before it is deleted when this delegate method returns.
        let dest = location.deletingLastPathComponent()
            .appendingPathComponent(location.lastPathComponent + ".downloaded")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            resume(throwing: HebrewModelDownloadError.writeFailed(location, underlying: error))
            return
        }
        resume(returning: dest)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        resume(throwing: HebrewModelDownloadError.network(underlying: error))
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressSink.submit(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    private func resume(returning url: URL) {
        lock.withLock {
            continuation?.resume(returning: url)
            continuation = nil
        }
    }

    private func resume(throwing error: Error) {
        lock.withLock {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

// MARK: - Task box (Sendable wrapper for URLSessionDownloadTask)

/// Thread-safe holder for a URLSessionDownloadTask so it can be safely
/// cancelled from the `withTaskCancellationHandler` onCancel closure.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?

    func store(_ task: URLSessionDownloadTask) {
        lock.withLock { self.task = task }
    }

    func cancel() {
        lock.withLock { task?.cancel() }
    }
}

// MARK: - Downloader

/// Downloads, verifies, and installs ivrit.ai CoreML models from GitHub Releases.
///
/// Cache layout:
///   `~/.transcribeer/models/models/argmaxinc/whisperkit-coreml/<extractedFolderName>/`
///
/// This path is identical to what `TranscriptionService.cachedModelFolder` scans so
/// WhisperKit picks up ivrit.ai models transparently — they sit alongside OpenAI variants
/// under the same `argmaxinc/whisperkit-coreml` prefix with no changes to TranscriptionService.
@Observable @MainActor
final class HebrewModelDownloader {
    // MARK: - Public state

    private(set) var progress: Double?
    private(set) var currentDownload: ModelManifestEntry?

    // MARK: - Private

    private let session: URLSession
    private let modelsBaseDir: URL
    private let logger = Logger(subsystem: "com.transcribeer", category: "model-downloader")

    /// Required CoreML bundles that must be present for a model to be considered installed.
    nonisolated private static let requiredBundles = [
        "AudioEncoder.mlmodelc",
        "TextDecoder.mlmodelc",
        "MelSpectrogram.mlmodelc",
    ]

    // MARK: - Init

    /// - Parameters:
    ///   - session: URLSession to use. Supply a custom session (with mock protocol) in tests.
    ///   - modelsBaseDir: Root for the WhisperKit cache layout. Defaults to
    ///     `~/.transcribeer/models/models/argmaxinc/whisperkit-coreml/`.
    init(session: URLSession = .shared, modelsBaseDir: URL? = nil) {
        self.session = session
        self.modelsBaseDir = modelsBaseDir ?? Self.defaultModelsBaseDir
    }

    nonisolated private static var defaultModelsBaseDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/models/models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    // MARK: - Public API

    /// Returns true when the model's three required `.mlmodelc` bundles are present in the cache.
    nonisolated func isInstalled(_ entry: ModelManifestEntry) -> Bool {
        let folder = modelsBaseDir.appendingPathComponent(entry.extractedFolderName, isDirectory: true)
        let fm = FileManager.default
        return Self.requiredBundles.allSatisfy { bundle in
            fm.fileExists(atPath: folder.appendingPathComponent(bundle).path)
        }
    }

    /// Download, verify, and install `entry`. No-op when already installed.
    ///
    /// - Throws: `HebrewModelDownloadError` on network failure, SHA mismatch, or extraction error.
    func download(_ entry: ModelManifestEntry) async throws {
        guard !isInstalled(entry) else {
            progress = 1.0
            return
        }

        currentDownload = entry
        progress = 0.0
        defer {
            currentDownload = nil
            progress = nil
        }

        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tarballDest = tmpDir.appendingPathComponent("\(entry.id).tar.zst")
        let extractDir = tmpDir.appendingPathComponent("extract", isDirectory: true)

        defer { try? fm.removeItem(at: tmpDir) }

        do {
            try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        } catch {
            throw HebrewModelDownloadError.writeFailed(tmpDir, underlying: error)
        }

        // Download
        let sink = DownloadProgressSink { [weak self] value in
            self?.progress = value
        }
        let downloadedURL = try await performDownload(
            url: entry.downloadURL,
            tarballDest: tarballDest,
            sink: sink
        )

        // SHA-256 verification
        if entry.sha256 == "__PENDING__" {
            logger.warning(
                "Skipping SHA-256 verification: sha256 is __PENDING__. Update ModelManifest.swift after upload."
            )
        } else {
            let digest = try computeSHA256(of: downloadedURL)
            guard digest == entry.sha256 else {
                try? fm.removeItem(at: downloadedURL)
                throw HebrewModelDownloadError.sha256Mismatch(expected: entry.sha256, got: digest)
            }
            logger.info("SHA-256 verified for \(entry.id, privacy: .public)")
        }

        // Extract tarball
        try await extract(tarball: downloadedURL, to: extractDir)

        // Atomic move into final cache location
        let extractedSource = extractDir.appendingPathComponent(entry.extractedFolderName, isDirectory: true)
        let finalDest = modelsBaseDir.appendingPathComponent(entry.extractedFolderName, isDirectory: true)

        do {
            try fm.createDirectory(at: modelsBaseDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: finalDest.path) {
                try fm.removeItem(at: finalDest)
            }
            try fm.moveItem(at: extractedSource, to: finalDest)
        } catch {
            throw HebrewModelDownloadError.writeFailed(finalDest, underlying: error)
        }

        progress = 1.0
        logger.info("Installed \(entry.id, privacy: .public) at \(finalDest.path, privacy: .sensitive)")
    }

    // MARK: - Private helpers

    private func performDownload(
        url: URL,
        tarballDest: URL,
        sink: DownloadProgressSink
    ) async throws -> URL {
        let delegate = DownloadDelegate(progressSink: sink)
        let cfg = URLSessionConfiguration.default
        let delegateSession = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        // Box the task so the onCancel closure can safely reach it across concurrency domains.
        let taskBox = TaskBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.setContinuation(continuation)
                let task = delegateSession.downloadTask(with: url)
                taskBox.store(task)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
            try? FileManager.default.removeItem(at: tarballDest)
        }
    }

    /// Extracts a `.tar.zst` (or any libarchive-supported format) into `destination`
    /// using the system `libarchive.2.dylib` directly — no external `zstd` binary required.
    nonisolated private func extract(tarball: URL, to destination: URL) async throws {
        let bufLen: Int32 = 1024
        var errorBuf = [CChar](repeating: 0, count: Int(bufLen))
        let result = zstd_extract(tarball.path, destination.path, &errorBuf, bufLen)
        guard result == 0 else {
            let stderr = String(cString: errorBuf)
            throw HebrewModelDownloadError.extractionFailed(exitCode: result, stderr: stderr)
        }
    }

    nonisolated private func computeSHA256(of url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw HebrewModelDownloadError.writeFailed(url, underlying: error)
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1024 * 1024 // 1 MB chunks
        while true {
            let chunk = handle.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
