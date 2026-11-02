import AVFoundation
import Foundation
import Testing
@testable import CaptureCore

// MARK: - Helpers

private func tempCAF() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("track_\(UUID().uuidString).caf")
}

private func tone(frames: Int, sampleRate: Double, value: Float = 0.5) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = try #require(buffer.floatChannelData)
    for index in 0..<frames {
        data[0][index] = value
    }
    return buffer
}

private func readFile(_ url: URL) throws -> (rate: Double, samples: [Float]) {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(file.length)
    ))
    try file.read(into: buffer)
    let data = try #require(buffer.floatChannelData)
    let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
    return (file.processingFormat.sampleRate, samples)
}

// MARK: - Tests

struct SourceTrackWriterTests {
    @Test("A sample-rate change mid-recording is converted, not dropped", arguments: [
        24_000.0, 16_000.0, 44_100.0,
    ])
    func convertsRateChange(newRate: Double) throws {
        let url = tempCAF()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = SourceTrackWriter(url: url)
        let start = Date()

        // 1 s at 48 kHz, then 1 s at the headset's hands-free rate.
        writer.write(try tone(frames: 48_000, sampleRate: 48_000), at: start)
        writer.write(
            try tone(frames: Int(newRate), sampleRate: newRate),
            at: start.addingTimeInterval(1)
        )
        writer.close()

        let (rate, samples) = try readFile(url)
        #expect(rate == 48_000)
        // The resampler may hold back a few frames of latency.
        #expect(abs(samples.count - 96_000) < 200)
    }

    @Test("At a new capture generation the wall-clock gap is filled with silence")
    func padsGapAfterDiscontinuity() throws {
        let url = tempCAF()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = SourceTrackWriter(url: url)
        let start = Date()

        // 0.1 s buffer, capture rebuilt, next 0.1 s buffer arrives 2.1 s later:
        // 2 s of audio are missing.
        writer.write(try tone(frames: 4_800, sampleRate: 48_000), at: start, generation: 1)
        writer.write(
            try tone(frames: 4_800, sampleRate: 48_000),
            at: start.addingTimeInterval(2.1),
            generation: 2
        )
        writer.close()

        let (_, samples) = try readFile(url)
        #expect(samples.count == 4_800 + 96_000 + 4_800)
        #expect(samples[4_800..<(4_800 + 96_000)].allSatisfy { $0 == 0 })
        #expect(samples.last == 0.5)
    }

    @Test("Within one capture generation, late buffers are not padded")
    func noPaddingWithoutDiscontinuity() throws {
        let url = tempCAF()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = SourceTrackWriter(url: url)
        let start = Date()

        writer.write(try tone(frames: 4_800, sampleRate: 48_000), at: start)
        writer.write(try tone(frames: 4_800, sampleRate: 48_000), at: start.addingTimeInterval(5))
        writer.close()

        #expect(try readFile(url).samples.count == 9_600)
    }

    @Test("Padding is capped so a bad clock can't write hours of silence")
    func paddingIsCapped() throws {
        let url = tempCAF()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = SourceTrackWriter(url: url)
        let start = Date()

        writer.write(try tone(frames: 480, sampleRate: 48_000), at: start, generation: 1)
        writer.write(try tone(frames: 480, sampleRate: 48_000), at: start.addingTimeInterval(3_600), generation: 2)
        writer.close()

        let padded = Int(SourceTrackWriter.maxPaddingSeconds * 48_000)
        #expect(try readFile(url).samples.count == 480 + padded + 480)
    }

    @Test("Old-generation buffers still queued don't consume the gap padding")
    func queuedOldBuffersDontConsumePadding() throws {
        let url = tempCAF()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = SourceTrackWriter(url: url)
        let start = Date()

        // Two old-capture buffers drain after the rebuild started, then the
        // new capture's first buffer arrives 3 s later.
        writer.write(try tone(frames: 4_800, sampleRate: 48_000), at: start, generation: 1)
        writer.write(try tone(frames: 4_800, sampleRate: 48_000), at: start.addingTimeInterval(0.1), generation: 1)
        writer.write(try tone(frames: 4_800, sampleRate: 48_000), at: start.addingTimeInterval(3.2), generation: 2)
        writer.close()

        #expect(writer.paddedFrames == 3 * 48_000)
        #expect(abs(writer.gapSeconds - 3) < 0.001)
    }
}
