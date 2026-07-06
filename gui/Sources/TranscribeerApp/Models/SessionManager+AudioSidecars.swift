import Foundation

extension SessionManager {
    struct AudioSidecarCleanup: Equatable {
        let removedFiles: [String]
        let bytesFreed: UInt64
    }

    /// Remove raw capture CAFs only after each source has a compressed M4A replacement.
    ///
    /// The mixed `audio.m4a` is not enough: retranscription needs per-source
    /// audio to preserve speaker labels. Raw CAFs are deleted per source only
    /// when `audio.mic.m4a` / `audio.sys.m4a` exists and is non-empty.
    @discardableResult
    static func removeCaptureAudioSidecars(in dir: URL) -> AudioSidecarCleanup {
        let fileManager = FileManager.default
        var removedFiles: [String] = []
        var bytesFreed: UInt64 = 0

        for sidecar in captureAudioSidecars {
            let raw = dir.appendingPathComponent(sidecar.raw)
            let compressed = dir.appendingPathComponent(sidecar.compressed)
            guard fileManager.fileExists(atPath: raw.path), fileSize(compressed) > 0 else {
                continue
            }

            let size = fileSize(raw)
            do {
                try fileManager.removeItem(at: raw)
                removedFiles.append(sidecar.raw)
                bytesFreed += size
            } catch {
                continue
            }
        }

        return AudioSidecarCleanup(removedFiles: removedFiles, bytesFreed: bytesFreed)
    }

    private static let captureAudioSidecars: [(raw: String, compressed: String)] = [
        (raw: "audio.mic.caf", compressed: "audio.mic.m4a"),
        (raw: "audio.sys.caf", compressed: "audio.sys.m4a"),
    ]

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
