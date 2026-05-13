import AVFoundation
import Foundation
import Testing
@testable import TranscribeerApp

struct SessionSplitterTests {
    // MARK: - On-disk audio trim

    /// Full end-to-end: synthesize a 10s m4a, split at 4s, confirm the
    /// original file on disk is actually ~4s long and the new session holds
    /// the ~6s tail. Guards against `AVAssetExportPresetPassthrough` silently
    /// ignoring `timeRange` on some formats (the symptom: original keeps
    /// playing the full pre-split audio).
    @Test("Split replaces original audio with the left half and writes the right half to a new session")
    @MainActor
    func splitsAudioOnDisk() async throws {
        let sessionsDir = try makeTempSessionsDir()
        defer { try? FileManager.default.removeItem(at: sessionsDir) }

        let sessionDir = SessionManager.newSession(sessionsDir: sessionsDir.path)
        let audioURL = sessionDir.appendingPathComponent("audio.m4a")
        try writeSilentM4A(to: audioURL, durationSeconds: 10)
        let originalDuration = try await assetDurationSeconds(audioURL)
        // Sanity: fixture really is ~10s before we split it.
        #expect(abs(originalDuration - 10) < 0.3, "fixture should be ~10s, got \(originalDuration)")

        let newDir = try await SessionSplitter.split(
            session: sessionDir,
            at: 4,
            sessionsDir: sessionsDir.path,
        )

        let leftURL = sessionDir.appendingPathComponent("audio.m4a")
        let rightURL = newDir.appendingPathComponent("audio.m4a")
        #expect(FileManager.default.fileExists(atPath: leftURL.path))
        #expect(FileManager.default.fileExists(atPath: rightURL.path))

        let leftDuration = try await assetDurationSeconds(leftURL)
        let rightDuration = try await assetDurationSeconds(rightURL)

        // AAC frames are 1024 samples @ 44.1kHz ≈ 23ms, so passthrough can
        // snap to the nearest frame. Allow ~0.25s slack either side.
        #expect(abs(leftDuration - 4) < 0.25, "original trimmed to ~4s, got \(leftDuration)")
        #expect(abs(rightDuration - 6) < 0.25, "new session has ~6s, got \(rightDuration)")
        #expect(leftDuration < originalDuration - 1, "original must be shorter than before split")
    }

    // MARK: - Audio fixture helpers

    private func makeTempSessionsDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribeer-splitter-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func assetDurationSeconds(_ url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }

    /// Write a mono AAC-in-M4A file of the requested duration filled with
    /// silence. Uses `AVAudioFile` in "writing" mode so the on-disk format is
    /// exactly what the app produces for real recordings.
    private func writeSilentM4A(to url: URL, durationSeconds: Double) throws {
        let sampleRate = 44_100.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false,
        )
        guard let pcmFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false,
        ) else {
            throw AudioFixtureError.formatSetupFailed
        }

        // Write in 0.5s chunks so each buffer stays small; AVAudioFile
        // transcodes to AAC on write.
        let chunkFrames = AVAudioFrameCount(sampleRate / 2)
        let totalFrames = AVAudioFrameCount(sampleRate * durationSeconds)
        var written: AVAudioFrameCount = 0
        while written < totalFrames {
            let thisChunk = min(chunkFrames, totalFrames - written)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: pcmFormat,
                frameCapacity: thisChunk,
            ) else {
                throw AudioFixtureError.bufferAllocFailed
            }
            buffer.frameLength = thisChunk
            // Zero-fill is already the default for freshly-allocated
            // `AVAudioPCMBuffer`s, so nothing else to do here.
            try file.write(from: buffer)
            written += thisChunk
        }
    }

    private enum AudioFixtureError: Error {
        case formatSetupFailed
        case bufferAllocFailed
    }

    // MARK: - Transcript partitioning

    @Test("Lines entirely before the split stay in the original; lines after shift to zero")
    func partitionsCleanBoundary() {
        let transcript = """
        [00:00 -> 00:30] Speaker 1: first
        [00:30 -> 01:00] Speaker 2: second
        [01:00 -> 01:30] Speaker 1: third
        """
        let (left, right) = SessionSplitter.partitionTranscript(transcript, at: 60)

        let leftLines = TranscriptFormatter.parse(left)
        let rightLines = TranscriptFormatter.parse(right)

        #expect(leftLines.count == 2)
        #expect(leftLines[0].start == 0)
        #expect(leftLines[0].end == 30)
        #expect(leftLines[1].start == 30)
        #expect(leftLines[1].end == 60)

        #expect(rightLines.count == 1)
        #expect(rightLines[0].start == 0)
        #expect(rightLines[0].end == 30)
        #expect(rightLines[0].speaker == "Speaker 1")
        #expect(rightLines[0].text == "third")
    }

    @Test("Cross-boundary line stays on the left with its end clamped to the split")
    func clampsCrossBoundaryLine() {
        let transcript = """
        [00:00 -> 00:10] Speaker 1: before
        [00:10 -> 01:00] Speaker 1: spans boundary
        [01:00 -> 01:20] Speaker 2: after
        """
        let (left, right) = SessionSplitter.partitionTranscript(transcript, at: 30)
        let leftLines = TranscriptFormatter.parse(left)
        let rightLines = TranscriptFormatter.parse(right)

        #expect(leftLines.count == 2)
        #expect(leftLines[1].start == 10)
        #expect(leftLines[1].end == 30, "Cross-boundary line clamped to split")

        #expect(rightLines.count == 1)
        #expect(rightLines[0].start == 30)
        #expect(rightLines[0].end == 50)
    }

    @Test("Preserves original speaker labels instead of renumbering")
    func preservesSpeakerLabels() {
        let transcript = """
        [00:00 -> 00:30] Speaker 3: one
        [00:30 -> 01:00] Speaker 7: two
        """
        let (_, right) = SessionSplitter.partitionTranscript(transcript, at: 30)
        let rightLines = TranscriptFormatter.parse(right)
        #expect(rightLines.first?.speaker == "Speaker 7")
    }

    @Test("Empty transcript round-trips as two empty strings")
    func emptyTranscript() {
        let (left, right) = SessionSplitter.partitionTranscript("", at: 5)
        #expect(left.isEmpty)
        #expect(right.isEmpty)
    }

    @Test("Split past every line leaves the right side empty")
    func splitPastEnd() {
        let transcript = "[00:00 -> 00:30] Speaker 1: only line"
        let (left, right) = SessionSplitter.partitionTranscript(transcript, at: 120)
        let leftLines = TranscriptFormatter.parse(left)
        #expect(leftLines.count == 1)
        #expect(right.isEmpty)
    }

    @Test("Split before every line leaves the left side empty")
    func splitBeforeStart() {
        let transcript = "[00:30 -> 01:00] Speaker 1: only line"
        let (left, right) = SessionSplitter.partitionTranscript(transcript, at: 10)
        #expect(left.isEmpty)
        let rightLines = TranscriptFormatter.parse(right)
        #expect(rightLines.count == 1)
        #expect(rightLines[0].start == 20)
        #expect(rightLines[0].end == 50)
    }

    // MARK: - Meta update

    @Test("Original gets endedAt = startedAt + split; new session starts that moment later")
    func metaSplitsRecordingWindow() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let endedAt = startedAt.addingTimeInterval(600)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let meta: [String: Any] = [
            "name": "Team sync",
            "startedAt": iso.string(from: startedAt),
            "endedAt": iso.string(from: endedAt),
            "language": "en",
        ]

        let update = SessionSplitter.computeMetaUpdate(originalMeta: meta, splitTime: 120)

        #expect(update.originalStartedAt == startedAt)
        #expect(update.originalEndedAt == startedAt.addingTimeInterval(120))
        #expect(update.newStartedAt == startedAt.addingTimeInterval(120))
        #expect(update.newEndedAt == endedAt)
        #expect(update.newName == "Team sync (Part 2)")
        #expect(update.language == "en")
    }

    @Test("Untitled session falls back to 'Untitled (Part 2)'")
    func untitledSessionSplit() {
        let update = SessionSplitter.computeMetaUpdate(originalMeta: [:], splitTime: 30)
        #expect(update.newName == "Untitled (Part 2)")
        #expect(update.originalStartedAt == nil)
        #expect(update.newStartedAt == nil)
    }

    @Test("Missing startedAt leaves endedAt untouched on the original side")
    func missingStartedAtKeepsEndedAt() {
        let endedAt = Date(timeIntervalSince1970: 1_700_000_600)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let meta: [String: Any] = [
            "name": "Solo",
            "endedAt": iso.string(from: endedAt),
        ]
        let update = SessionSplitter.computeMetaUpdate(originalMeta: meta, splitTime: 60)

        // Without startedAt we can't compute a split timestamp, so we leave
        // the existing endedAt in place rather than invent one.
        #expect(update.originalEndedAt == endedAt)
        #expect(update.newEndedAt == endedAt)
        #expect(update.newStartedAt == nil)
    }
}
