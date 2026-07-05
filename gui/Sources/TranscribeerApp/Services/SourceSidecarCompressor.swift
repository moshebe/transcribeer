import Foundation
import TranscribeerCore

/// Compresses raw per-source CAF recordings into compact M4A sidecars.
///
/// The app still captures to CAF because append-only PCM is reliable during a
/// live recording. At session finalization, these raw sidecars are replaced by
/// `audio.mic.m4a` / `audio.sys.m4a` so later retranscription can preserve
/// source labels without keeping large PCM files around.
enum SourceSidecarCompressor {
    struct Report: Sendable, Equatable {
        var compressed: [FileReport] = []
        var skipped: [String] = []
        var failed: [String] = []

        var compressedCount: Int { compressed.count }
        var methods: [String] { Array(Set(compressed.map(\.method))).sorted() }
    }

    struct FileReport: Sendable, Equatable {
        let source: String
        let method: String
        let rawBytes: UInt64
        let compressedBytes: UInt64
    }

    struct MaintenanceReport: Sendable, Equatable {
        var sessionsScanned = 0
        var sessionsWithRawSidecars = 0
        var compressedFiles = 0
        var removedFiles = 0
        var bytesFreed: UInt64 = 0
        var failed: [String] = []

        var didWork: Bool {
            compressedFiles > 0 || removedFiles > 0 || !failed.isEmpty
        }
    }

    static func compressSession(in session: URL, ffmpegPath: String) async -> Report {
        let service = AudioProcessingService(configuredFFmpegPath: ffmpegPath)
        return await compressSession(in: session, service: service)
    }

    static func maintainHistoricalSessions(
        in sessionsDir: String,
        ffmpegPath: String
    ) async -> MaintenanceReport {
        let service = AudioProcessingService(configuredFFmpegPath: ffmpegPath)
        let url = URL(fileURLWithPath: (sessionsDir as NSString).expandingTildeInPath)
        return await maintainHistoricalSessions(in: url, service: service)
    }

    static func maintainHistoricalSessions(
        in sessionsDir: URL,
        service: AudioProcessingService
    ) async -> MaintenanceReport {
        await Task.detached(priority: .utility) {
            await maintainHistoricalSessionsWork(in: sessionsDir, service: service)
        }.value
    }

    static func compressSession(
        in session: URL,
        service: AudioProcessingService
    ) async -> Report {
        await Task.detached(priority: .utility) {
            await compressSessionWork(in: session, service: service)
        }.value
    }

    private static func compressSessionWork(
        in session: URL,
        service: AudioProcessingService
    ) async -> Report {
        var report = Report()

        for source in SourceAudioFiles.Source.allCases {
            let raw = SourceAudioFiles.rawURL(in: session, source: source)
            let compressed = SourceAudioFiles.compressedURL(in: session, source: source)
            guard SourceAudioFiles.isNonEmpty(raw) else {
                report.skipped.append(source.rawValue)
                continue
            }

            do {
                let file = try await compress(raw: raw, compressed: compressed, service: service)
                report.compressed.append(FileReport(
                    source: source.rawValue,
                    method: file.method,
                    rawBytes: file.rawBytes,
                    compressedBytes: file.compressedBytes
                ))
            } catch {
                report.failed.append("\(source.rawValue): \(error.localizedDescription)")
            }
        }

        return report
    }

    private static func maintainHistoricalSessionsWork(
        in sessionsDir: URL,
        service: AudioProcessingService
    ) async -> MaintenanceReport {
        var report = MaintenanceReport()
        for session in sessionDirectories(in: sessionsDir) {
            report.sessionsScanned += 1
            guard hasRawSidecars(in: session) else { continue }
            report.sessionsWithRawSidecars += 1
            guard hasStableSessionArtifact(in: session) else { continue }

            let compression = await compressSession(in: session, service: service)
            let cleanup = SessionManager.removeCaptureAudioSidecars(in: session)
            report.compressedFiles += compression.compressedCount
            report.removedFiles += cleanup.removedFiles.count
            report.bytesFreed += cleanup.bytesFreed
            report.failed.append(contentsOf: compression.failed.map { failure in
                "\(session.lastPathComponent): \(failure)"
            })
        }
        return report
    }

    private static func sessionDirectories(in sessionsDir: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func hasRawSidecars(in session: URL) -> Bool {
        SourceAudioFiles.Source.allCases.contains { source in
            SourceAudioFiles.isNonEmpty(SourceAudioFiles.rawURL(in: session, source: source))
        }
    }

    private static func hasStableSessionArtifact(in session: URL) -> Bool {
        SessionManager.audioURL(in: session) != nil
            || FileManager.default.fileExists(atPath: session.appendingPathComponent("transcript.txt").path)
            || FileManager.default.fileExists(atPath: session.appendingPathComponent("summary.md").path)
    }

    private struct CompressedFile {
        let method: String
        let rawBytes: UInt64
        let compressedBytes: UInt64
    }

    private static func compress(
        raw: URL,
        compressed: URL,
        service: AudioProcessingService
    ) async throws -> CompressedFile {
        let request = AudioTranscodeRequest(inputURL: raw, outputURL: compressed)
        let result = try await service.transcode(request)
        guard SourceAudioFiles.isNonEmpty(compressed) else {
            throw AudioProcessingError.emptyOutput(compressed)
        }
        return CompressedFile(
            method: result.backendID,
            rawBytes: fileSize(raw),
            compressedBytes: result.outputBytes
        )
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return 0
        }
        return switch attributes[.size] {
        case let size as UInt64: size
        case let size as NSNumber: size.uint64Value
        default: 0
        }
    }
}
