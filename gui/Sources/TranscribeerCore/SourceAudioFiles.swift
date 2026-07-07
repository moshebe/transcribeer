import Foundation

/// Canonical filenames for per-source recordings.
///
/// Capture writes raw CAF files first because they are cheap append targets.
/// Session finalization may replace them with compressed M4A sidecars for
/// long-term storage; transcription should accept either shape.
public enum SourceAudioFiles {
    public enum Source: String, CaseIterable, Sendable {
        case mic
        case sys
    }

    public static func rawURL(in session: URL, source: Source) -> URL {
        session.appendingPathComponent("audio.\(source.rawValue).caf")
    }

    public static func compressedURL(in session: URL, source: Source) -> URL {
        session.appendingPathComponent("audio.\(source.rawValue).m4a")
    }

    public static func preferredURL(in session: URL, source: Source) -> URL? {
        let raw = rawURL(in: session, source: source)
        if isNonEmpty(raw) { return raw }

        let compressed = compressedURL(in: session, source: source)
        return isNonEmpty(compressed) ? compressed : nil
    }

    public static func isNonEmpty(_ url: URL) -> Bool {
        byteCount(url) > 0
    }

    /// Size of the file at `url` in bytes, or 0 if it can't be read.
    public static func byteCount(_ url: URL) -> UInt64 {
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
