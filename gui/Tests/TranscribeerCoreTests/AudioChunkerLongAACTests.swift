import AVFoundation
import Foundation
import Testing
@testable import TranscribeerCore

/// Regression coverage for the long-recording AAC chunking bug seen in
/// session `2026-05-11-1515`: the cloud path produced m4a chunks that
/// OpenAI's audio API parsed as `duration: 0`, causing every chunk upload
/// to fail with HTTP 400 `audio_too_short`. Root cause hypothesis: at
/// production chunk sizes (~600 s / ~26 M source frames) the single-shot
/// `AVAudioConverter.convert(to:error:withInputFrom:)` call inside
/// `AudioChunker.resample` does not drain all output frames, so the
/// downstream AAC writer receives a 0-frame buffer.
///
/// These tests drive `AudioChunker.split` at production-realistic sizes
/// and assert each emitted chunk decodes back to a non-trivial duration.
struct AudioChunkerLongAACTests {
    /// Write a non-silent CAF (200 Hz sine, mono Float32) at `sampleRate`
    /// for `durationSeconds`. Non-silence matters: a fully zeroed AAC
    /// stream could in principle be optimized down by the encoder, so we
    /// use a real signal to ensure the decoded duration reflects actual
    /// encoded frames.
    private static func writeSineCAF(
        durationSeconds: Double,
        sampleRate: Double
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("long-aac-\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ChunkError.invalidWAV
        }
        // Stream the source in 1 s blocks instead of one giant buffer so
        // even a 600 s test doesn't allocate 100+ MB of contiguous PCM.
        let blockFrames = AVAudioFrameCount(sampleRate)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: blockFrames
        ) else {
            throw ChunkError.invalidWAV
        }
        let totalFrames = Int(durationSeconds * sampleRate)
        var framePos = 0
        let twoPiOverRate = 2 * Double.pi * 200.0 / sampleRate
        while framePos < totalFrames {
            let frames = min(Int(blockFrames), totalFrames - framePos)
            buffer.frameLength = AVAudioFrameCount(frames)
            if let channel = buffer.floatChannelData?[0] {
                for i in 0..<frames {
                    channel[i] = Float(sin(Double(framePos + i) * twoPiOverRate)) * 0.3
                }
            }
            try file.write(from: buffer)
            framePos += frames
        }
        return url
    }

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("long-aac-chunks-\(UUID().uuidString)")
    }

    /// Table of (source duration, chunk size). The 600 s case mirrors the
    /// production `CloudTranscriptionService.chunkSeconds` value; the
    /// smaller cases exist so this test isn't ~60 s slow on its own.
    @Test(
        "long AAC chunks have non-zero decoded duration",
        arguments: [
            (sourceSeconds: 65.0, chunkSeconds: 60.0),
            (sourceSeconds: 125.0, chunkSeconds: 60.0),
            (sourceSeconds: 605.0, chunkSeconds: 600.0),
        ]
    )
    func longAACChunksDecodeToFullDuration(
        sourceSeconds: Double,
        chunkSeconds: Double
    ) throws {
        // 44.1 kHz mirrors the mic.caf format DualAudioRecorder produces.
        let src = try Self.writeSineCAF(
            durationSeconds: sourceSeconds,
            sampleRate: 44_100
        )
        let tempDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let chunks = try AudioChunker.split(
            source: src,
            chunkDuration: chunkSeconds,
            targetSampleRate: 16_000,
            outputFormat: .aacM4A(bitrate: 48_000),
            tempDir: tempDir
        )
        #expect(!chunks.isEmpty, "expected at least one chunk")

        for (index, chunk) in chunks.enumerated() {
            let bytes = try Data(contentsOf: chunk.url).count
            #expect(
                bytes > 1_000,
                "chunk[\(index)] is suspiciously small: \(bytes) bytes"
            )
            let duration = try #require(
                AudioChunker.wavDuration(url: chunk.url),
                "chunk[\(index)] failed to open via AVAudioFile"
            )
            #expect(
                duration > 0.1,
                "chunk[\(index)] decoded to \(duration) s — OpenAI would reject as audio_too_short"
            )

            // Each chunk should be within ~5% of its expected length
            // (full chunkSeconds for all but the last, which holds the tail).
            let isLast = index == chunks.count - 1
            let expected = isLast ? sourceSeconds - chunk.startOffset : chunkSeconds
            #expect(
                abs(duration - expected) < max(0.5, expected * 0.05),
                "chunk[\(index)] duration \(duration) s, expected ~\(expected) s"
            )
        }
    }
}
