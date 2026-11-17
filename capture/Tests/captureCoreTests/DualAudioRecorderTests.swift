import AVFoundation
import Foundation
import Testing
@testable @_spi(Testing) import CaptureCore

// MARK: - Helpers

private func makeSessionDir() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("recorder_\(UUID().uuidString)")
}

private func pcmBuffer(
    samples: [Float],
    sampleRate: Double = 48000,
    channels: UInt32 = 1
) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channels,
        interleaved: false
    ))
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(samples.count)
    ))
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let channelData = try #require(buffer.floatChannelData)
    for ch in 0..<Int(channels) {
        for (i, s) in samples.enumerated() {
            channelData[ch][i] = s
        }
    }
    return buffer
}

private func readCafFrames(at url: URL) -> Int64 {
    guard let file = try? AVAudioFile(forReading: url) else { return 0 }
    return file.length
}

// MARK: - Tests

struct DualAudioRecorderTests {
    @Test("CAF frame count matches written mic buffers")
    func micFrameCount() async throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let recorder = DualAudioRecorder(sessionDir: dir)
        let samples = (0..<4800).map { Float(sin(Double($0) * 0.1)) * 0.5 }
        try recorder.writeMic(pcmBuffer(samples: samples))
        try recorder.writeMic(pcmBuffer(samples: samples))

        _ = await recorder.stop()

        let micURL = dir.appendingPathComponent("audio.mic.caf")
        #expect(FileManager.default.fileExists(atPath: micURL.path))
        #expect(readCafFrames(at: micURL) == 9600)
    }

    @Test("CAF frame count matches written sys buffers")
    func sysFrameCount() async throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let recorder = DualAudioRecorder(sessionDir: dir)
        let samples = (0..<2400).map { Float(cos(Double($0) * 0.2)) * 0.3 }
        try recorder.writeSys(pcmBuffer(samples: samples, sampleRate: 48000))
        try recorder.writeSys(pcmBuffer(samples: samples, sampleRate: 48000))

        let timing = await recorder.stop()

        let sysURL = dir.appendingPathComponent("audio.sys.caf")
        #expect(FileManager.default.fileExists(atPath: sysURL.path))
        #expect(readCafFrames(at: sysURL) == 4800)
        #expect(timing.sysDeclaredSampleRate == 48000)
    }

    @Test("Anchors are populated after first buffer")
    func anchorsPopulated() async throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let recorder = DualAudioRecorder(sessionDir: dir)
        try recorder.writeMic(pcmBuffer(samples: [0.1, 0.2, 0.3]))
        try recorder.writeSys(pcmBuffer(samples: [0.4, 0.5, 0.6]))

        let timing = await recorder.stop()

        #expect(timing.micStartEpoch != nil)
        #expect(timing.sysStartEpoch != nil)
    }

    @Test("Mic stereo is downmixed to mono")
    func micDownmix() async throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let recorder = DualAudioRecorder(sessionDir: dir)
        // Stereo buffer: L = 0.5, R = 0.3 → expected mono = 0.4
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        ))
        let stereo = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        stereo.frameLength = 100
        let stereoData = try #require(stereo.floatChannelData)
        for i in 0..<100 {
            stereoData[0][i] = 0.5
            stereoData[1][i] = 0.3
        }
        recorder.writeMic(stereo)

        _ = await recorder.stop()

        let micURL = dir.appendingPathComponent("audio.mic.caf")
        let file = try AVAudioFile(forReading: micURL)
        #expect(file.processingFormat.channelCount == 1)
        #expect(file.length == 100)
        let mono = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 100))
        try file.read(into: mono)
        let data = try #require(mono.floatChannelData)
        try #require(mono.frameLength == 100)
        for index in 0..<100 {
            #expect(abs(data[0][index] - 0.4) < 0.0001)
        }
    }

    @Test("Effective sample rate is computed from sys timing")
    func effectiveSampleRate() async throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let recorder = DualAudioRecorder(sessionDir: dir)
        let samples = (0..<48000).map { Float(sin(Double($0) * 0.01)) * 0.5 }
        let start = Date()
        // Two 1 s buffers arriving 2 s apart: the device delivered 96 000
        // frames over 2 s of wall clock, i.e. 48 kHz.
        try recorder.writeSys(pcmBuffer(samples: samples, sampleRate: 48000), at: start)
        try recorder.writeSys(pcmBuffer(samples: samples, sampleRate: 48000), at: start.addingTimeInterval(2))

        let timing = await recorder.stop()

        #expect(timing.sysEffectiveSampleRate == 48000)
        #expect(timing.sysDeclaredSampleRate == 48000)
    }

    @Test("Effective sample rate is left unset for sub-second recordings")
    func effectiveSampleRateTooShort() async throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let recorder = DualAudioRecorder(sessionDir: dir)
        try recorder.writeSys(pcmBuffer(samples: [0.1, 0.2, 0.3]))

        let timing = await recorder.stop()

        // A single buffer has zero duration; dividing by it produced `inf`,
        // which `timing.json` cannot encode.
        #expect(timing.sysEffectiveSampleRate == 0)
    }

    @Test("A long outage doesn't skew the effective rate of the captured audio")
    func effectiveRateIgnoresOutage() async throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let recorder = DualAudioRecorder(sessionDir: dir)
        let second = (0..<48_000).map { _ in Float(0.2) }
        let start = Date()
        // 1 s, 1 s, then a 90 s outage (padding capped at 30 s), then 1 s.
        try recorder.writeSys(pcmBuffer(samples: second), at: start, generation: 1)
        try recorder.writeSys(pcmBuffer(samples: second), at: start.addingTimeInterval(1), generation: 1)
        try recorder.writeSys(pcmBuffer(samples: second), at: start.addingTimeInterval(92), generation: 2)

        let timing = await recorder.stop()

        // 3 s captured over 2 s between first and last arrival, outage excluded.
        #expect(abs(timing.sysEffectiveSampleRate - 48_000 * 3 / 2) < 1)
        #expect(timing.sysDeclaredSampleRate == 48_000)
    }
}
