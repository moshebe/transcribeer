import AVFoundation
import Foundation
import os

/// Splits an existing recording at a given timestamp into two sessions:
/// the original is truncated to `[0, splitTime]` and a freshly created
/// session holds `[splitTime, duration]` with all timestamps shifted to
/// start at zero.
///
/// Only the mixed audio file (`audio.m4a` / `audio.wav`) is split. Dual-source
/// artifacts (`audio.mic.caf`, `audio.sys.caf`, `timing.json`) are removed
/// from both sides so any future re-transcribe falls back to the legacy
/// mixed-audio path and can't reach beyond the split boundary via the
/// original CAF files.
enum SessionSplitter {
    // MARK: - Errors

    enum SplitError: LocalizedError {
        case noAudio
        case invalidTime(TimeInterval, TimeInterval)
        case exportSetupFailed
        case exportFailed(String)
        case audioDurationUnknown

        var errorDescription: String? {
            switch self {
            case .noAudio:
                "Session has no audio to split."
            case let .invalidTime(time, duration):
                "Split time \(Int(time))s is outside the recording (0…\(Int(duration))s)."
            case .exportSetupFailed:
                "Could not set up the audio export session."
            case let .exportFailed(message):
                "Audio export failed: \(message)"
            case .audioDurationUnknown:
                "Could not read the recording's duration."
            }
        }
    }

    private static let logger = Logger(subsystem: "com.transcribeer", category: "SessionSplitter")

    /// Minimum distance from either edge we require before allowing a split.
    /// Mirrors the view-level disable threshold so the two stay in sync.
    static let minEdgeDistance: TimeInterval = 1.0

    // MARK: - Public API

    /// Split `sessionDir` at `splitTime` (seconds into the recording).
    ///
    /// - Returns: URL of the newly created session holding the tail of the
    ///   recording.
    @MainActor
    static func split(
        session sessionDir: URL,
        at splitTime: TimeInterval,
        sessionsDir: String
    ) async throws -> URL {
        guard let audioURL = SessionManager.audioURL(in: sessionDir) else {
            throw SplitError.noAudio
        }

        let asset = AVURLAsset(url: audioURL)
        let duration = try await assetDurationSeconds(asset)
        guard duration > 0 else { throw SplitError.audioDurationUnknown }
        guard splitTime >= minEdgeDistance,
              splitTime <= duration - minEdgeDistance else {
            throw SplitError.invalidTime(splitTime, duration)
        }

        // 1. Materialise both halves to temp files first. Touch the
        //    on-disk session only after both exports succeed so a failure
        //    leaves the original session intact.
        let fileType = audioFileType(for: audioURL)
        let ext = audioURL.pathExtension.lowercased()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribeer-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let leftTemp = tempDir.appendingPathComponent("left.\(ext)")
        let rightTemp = tempDir.appendingPathComponent("right.\(ext)")
        try await export(asset: asset, to: leftTemp, start: 0, end: splitTime, fileType: fileType)
        try await export(asset: asset, to: rightTemp, start: splitTime, end: duration, fileType: fileType)

        // 2. Create the new session directory and move the right half in.
        let newSessionDir = SessionManager.newSession(sessionsDir: sessionsDir)
        let targetAudioName = "audio.\(ext == "wav" ? "wav" : "m4a")"
        let newAudioURL = newSessionDir.appendingPathComponent(targetAudioName)
        try FileManager.default.moveItem(at: rightTemp, to: newAudioURL)

        // 3. Replace the original's audio with the truncated left half.
        _ = try? FileManager.default.removeItem(at: audioURL)
        try FileManager.default.moveItem(at: leftTemp, to: audioURL)

        // 4. Strip dual-source artifacts from both sides. Keeping them would
        //    let a later re-transcribe on the original reach past the split
        //    (via the untrimmed CAF files) and produce garbage on the new
        //    session (whose timing.json epochs no longer match).
        removeDualSourceArtifacts(in: sessionDir)

        // 5. Split the transcript and write each half to its session.
        splitTranscript(
            originalDir: sessionDir,
            newDir: newSessionDir,
            splitTime: splitTime
        )

        // 6. Update metadata on both sides (times, language, name).
        updateMetadata(
            originalDir: sessionDir,
            newDir: newSessionDir,
            splitTime: splitTime
        )

        logger.info("Split session at \(splitTime, privacy: .public)s → new session at \(newSessionDir.path, privacy: .public)")
        return newSessionDir
    }

    // MARK: - Transcript

    /// Split a transcript string into `(original, new)`. Lines with
    /// `start < splitTime` stay in the original; the rest are shifted so
    /// the first surviving line starts at zero.
    ///
    /// Exposed `internal` for unit testing.
    static func partitionTranscript(
        _ transcript: String,
        at splitTime: TimeInterval
    ) -> (left: String, right: String) {
        let lines = TranscriptFormatter.parse(transcript)
        guard !lines.isEmpty else { return ("", "") }

        var leftSegments: [LabeledSegment] = []
        var rightSegments: [LabeledSegment] = []
        for line in lines {
            if line.start < splitTime {
                // Clamp the tail of a cross-boundary line so the original
                // transcript's end timestamp doesn't claim audio that no
                // longer exists there.
                let end = min(line.end, splitTime)
                leftSegments.append(LabeledSegment(
                    start: line.start,
                    end: end,
                    speaker: line.speaker,
                    text: line.text
                ))
            } else {
                rightSegments.append(LabeledSegment(
                    start: line.start - splitTime,
                    end: max(0, line.end - splitTime),
                    speaker: line.speaker,
                    text: line.text
                ))
            }
        }

        return (
            left: renderTranscript(leftSegments),
            right: renderTranscript(rightSegments)
        )
    }

    /// Rebuild a transcript string directly from labelled segments without
    /// renumbering speakers (unlike `TranscriptFormatter.format`, which
    /// rewrites speaker IDs). Splitting must preserve existing labels so the
    /// new session's speakers line up with the original's.
    private static func renderTranscript(_ segments: [LabeledSegment]) -> String {
        guard !segments.isEmpty else { return "" }
        return segments.map { seg in
            let start = TranscriptFormatter.formatTimestamp(seg.start)
            let end = TranscriptFormatter.formatTimestamp(seg.end)
            return "[\(start) -> \(end)] \(seg.speaker): \(seg.text)"
        }.joined(separator: "\n")
    }

    private static func splitTranscript(
        originalDir: URL,
        newDir: URL,
        splitTime: TimeInterval
    ) {
        let originalPath = originalDir.appendingPathComponent("transcript.txt")
        guard let text = try? String(contentsOf: originalPath, encoding: .utf8),
              !text.isEmpty else { return }

        let (left, right) = partitionTranscript(text, at: splitTime)
        writeOrRemove(text: left, at: originalPath)
        if !right.isEmpty {
            let newPath = newDir.appendingPathComponent("transcript.txt")
            try? right.write(to: newPath, atomically: true, encoding: .utf8)
        }
    }

    private static func writeOrRemove(text: String, at url: URL) {
        if text.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Metadata

    /// Derived meta updates applied to both sides of a split.
    ///
    /// Exposed `internal` for unit testing.
    struct SplitMetaUpdate: Equatable {
        let originalStartedAt: Date?
        let originalEndedAt: Date?
        let newStartedAt: Date?
        let newEndedAt: Date?
        let newName: String
        let language: String?
    }

    /// Pure helper that derives the new meta values. All date math lives
    /// here so tests can pin it without poking AVFoundation.
    static func computeMetaUpdate(
        originalMeta: [String: Any],
        splitTime: TimeInterval
    ) -> SplitMetaUpdate {
        let startedAt = parseDate(originalMeta["startedAt"])
        let endedAt = parseDate(originalMeta["endedAt"])
        let language = originalMeta["language"] as? String

        let newStartedAt = startedAt.map { $0.addingTimeInterval(splitTime) }
        let newEndedAt = endedAt
        let originalEndedAt = startedAt.map { $0.addingTimeInterval(splitTime) } ?? endedAt

        let rawName = (originalMeta["name"] as? String) ?? ""
        let baseName = rawName.isEmpty ? "Untitled" : rawName
        let newName = "\(baseName) (Part 2)"

        return SplitMetaUpdate(
            originalStartedAt: startedAt,
            originalEndedAt: originalEndedAt,
            newStartedAt: newStartedAt,
            newEndedAt: newEndedAt,
            newName: newName,
            language: language
        )
    }

    private static func updateMetadata(
        originalDir: URL,
        newDir: URL,
        splitTime: TimeInterval
    ) {
        let originalMeta = SessionManager.readMeta(originalDir)
        let update = computeMetaUpdate(originalMeta: originalMeta, splitTime: splitTime)

        SessionManager.setRecordingTimes(
            originalDir,
            startedAt: update.originalStartedAt,
            endedAt: update.originalEndedAt
        )

        SessionManager.setName(newDir, update.newName)
        SessionManager.setRecordingTimes(
            newDir,
            startedAt: update.newStartedAt,
            endedAt: update.newEndedAt
        )
        if let language = update.language, !language.isEmpty {
            SessionManager.setLanguage(newDir, language)
        }
    }

    // MARK: - Filesystem helpers

    private static func removeDualSourceArtifacts(in dir: URL) {
        let names = ["audio.mic.caf", "audio.sys.caf", "timing.json"]
        let fm = FileManager.default
        for name in names {
            let url = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - AVFoundation glue

    private static func audioFileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "wav": .wav
        case "caf": .caf
        default: .m4a
        }
    }

    private static func assetDurationSeconds(_ asset: AVURLAsset) async throws -> TimeInterval {
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }

    private static func export(
        asset: AVURLAsset,
        to outputURL: URL,
        start: TimeInterval,
        end: TimeInterval,
        fileType: AVFileType
    ) async throws {
        guard let export = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw SplitError.exportSetupFailed
        }
        // Use a 1ms timescale — we never ask the user to pick a sub-millisecond
        // split point and a shared timescale keeps `CMTimeRange` math honest.
        let startTime = CMTime(seconds: max(0, start), preferredTimescale: 1000)
        let endTime = CMTime(seconds: end, preferredTimescale: 1000)
        export.timeRange = CMTimeRange(start: startTime, end: endTime)

        do {
            try await export.export(to: outputURL, as: fileType)
        } catch {
            throw SplitError.exportFailed(error.localizedDescription)
        }
    }

    // MARK: - Date parsing

    private static let isoFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let string = raw as? String, !string.isEmpty else { return nil }
        if let date = isoFormatter.date(from: string) { return date }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: string)
    }
}
