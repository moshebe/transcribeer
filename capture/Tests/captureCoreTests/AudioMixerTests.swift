import AVFoundation
import Foundation
import Testing
@testable import CaptureCore

// MARK: - Helpers

private func makeSessionDir() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mixer_\(UUID().uuidString)")
}

private func writeCaf(
    url: URL,
    samples: [Float],
    sampleRate: Double,
    channels: UInt32 = 1
) throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: channels,
        interleaved: false
    ))
    let frameCount = AVAudioFrameCount(samples.count / Int(channels))
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: frameCount
    ))
    buffer.frameLength = frameCount
    let channelData = try #require(buffer.floatChannelData)
    for ch in 0..<Int(channels) {
        for i in 0..<Int(frameCount) {
            channelData[ch][i] = samples[i * Int(channels) + ch]
        }
    }

    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
    ]
    let file = try AVAudioFile(
        forWriting: url,
        settings: settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    try file.write(from: buffer)
}

private func readSamples(at url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: file.fileFormat.sampleRate,
        channels: 1,
        interleaved: false
    ))
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    else {
        return []
    }
    try file.read(into: buffer)
    let channelData = try #require(buffer.floatChannelData)
    return Array(UnsafeBufferPointer(
        start: channelData[0],
        count: Int(buffer.frameLength)
    ))
}

private func sineWave(
    frequency: Double,
    sampleRate: Double,
    duration: Double,
    amplitude: Float = 0.5
) -> [Float] {
    let count = Int(duration * sampleRate)
    return (0..<count).map { i in
        Float(sin(2.0 * .pi * frequency * Double(i) / sampleRate)) * amplitude
    }
}

private func silence(duration: Double, sampleRate: Double) -> [Float] {
    [Float](repeating: 0, count: Int(duration * sampleRate))
}

/// Measure dominant frequency by counting positive-going zero crossings.
private func dominantFrequency(
    samples: [Float],
    sampleRate: Double
) -> Double {
    var crossings = 0
    for i in 1..<samples.count {
        if samples[i - 1] < 0 && samples[i] >= 0 {
            crossings += 1
        }
    }
    let dur = Double(samples.count) / sampleRate
    return Double(crossings) / dur
}

/// RMS energy of a slice.
private func rms(_ samples: [Float]) -> Float {
    guard !samples.isEmpty else { return 0 }
    let sumSq = samples.reduce(0) { $0 + $1 * $1 }
    return sqrt(sumSq / Float(samples.count))
}

// MARK: - Tests

struct AudioMixerTests {
    @Test("Mixing two tones produces their combined peak")
    func syntheticMix() throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let micURL = dir.appendingPathComponent("audio.mic.caf")
        let sysURL = dir.appendingPathComponent("audio.sys.caf")
        let outURL = dir.appendingPathComponent("audio.m4a")

        // Mic: 0.5s tone at 1 kHz
        let micTone = sineWave(frequency: 1000, sampleRate: 48000, duration: 0.5, amplitude: 0.5)
        // Sys: 0.5s tone at 2 kHz
        let sysTone = sineWave(frequency: 2000, sampleRate: 48000, duration: 0.5, amplitude: 0.3)

        try writeCaf(url: micURL, samples: micTone, sampleRate: 48000)
        try writeCaf(url: sysURL, samples: sysTone, sampleRate: 48000)

        let mixer = AudioMixer()
        let timing = TimingMetadata(
            micStartEpoch: 0,
            sysStartEpoch: 0,
            sysDeclaredSampleRate: 48000,
            sysEffectiveSampleRate: 48000
        )
        try mixer.mix(micURL: micURL, sysURL: sysURL, timing: timing, outputURL: outURL)

        let output = try readSamples(at: outURL)
        #expect(!output.isEmpty)

        let peak = output.map(abs).max() ?? 0
        // 0.5 + 0.3 = 0.8, hard-clipped at 1.0
        #expect(peak > 0.7 && peak <= 1.0)
    }

    @Test("Resample + retag preserves 1 kHz tone within 0.1%")
    func retagAccuracy() throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let sysURL = dir.appendingPathComponent("audio.sys.caf")
        let outURL = dir.appendingPathComponent("audio.m4a")

        let effectiveSR = 44_100.0
        let tone = sineWave(frequency: 1000, sampleRate: effectiveSR, duration: 2.0, amplitude: 0.8)
        try writeCaf(url: sysURL, samples: tone, sampleRate: 48_000)

        let micURL = dir.appendingPathComponent("audio.mic.caf")
        try writeCaf(url: micURL, samples: silence(duration: 2.0, sampleRate: 48000), sampleRate: 48000)

        let mixer = AudioMixer()
        let timing = TimingMetadata(
            micStartEpoch: 0,
            sysStartEpoch: 0,
            sysDeclaredSampleRate: 48_000,
            sysEffectiveSampleRate: effectiveSR
        )
        try mixer.mix(micURL: micURL, sysURL: sysURL, timing: timing, outputURL: outURL)

        let output = try readSamples(at: outURL)
        // Skip first 10 ms to avoid AAC priming delay
        let skip = Int(0.01 * 48000)
        let measured = dominantFrequency(
            samples: Array(output.dropFirst(skip)),
            sampleRate: 48000
        )
        let expected = 1000.0
        let errorPct = abs(measured - expected) / expected
        #expect(errorPct < 0.001, "Frequency error \(errorPct * 100)% exceeds 0.1%")
    }

    @Test("Timeline alignment: sys delayed by 2 seconds")
    func timelineAlignment() throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let micURL = dir.appendingPathComponent("audio.mic.caf")
        let sysURL = dir.appendingPathComponent("audio.sys.caf")
        let outURL = dir.appendingPathComponent("audio.m4a")

        // Mic: 1 kHz tone for 3 seconds
        let micTone = sineWave(frequency: 1000, sampleRate: 48000, duration: 3.0, amplitude: 0.5)
        // Sys: 2 kHz tone for 3 seconds (starts 2s later in real time)
        let sysTone = sineWave(frequency: 2000, sampleRate: 48000, duration: 3.0, amplitude: 0.5)

        try writeCaf(url: micURL, samples: micTone, sampleRate: 48000)
        try writeCaf(url: sysURL, samples: sysTone, sampleRate: 48000)

        let mixer = AudioMixer()
        let timing = TimingMetadata(
            micStartEpoch: 0,
            sysStartEpoch: 2.0,
            sysDeclaredSampleRate: 48000,
            sysEffectiveSampleRate: 48000
        )
        try mixer.mix(micURL: micURL, sysURL: sysURL, timing: timing, outputURL: outURL)

        let output = try readSamples(at: outURL)
        let sr = 48000.0

        // Window 0-1s: only mic (1 kHz)
        try #require(output.count >= Int(4.8 * sr))
        let early = Array(output[0..<Int(sr)])
        let earlyFreq = dominantFrequency(samples: early, sampleRate: sr)
        #expect(abs(earlyFreq - 1000) < 50, "Expected ~1 kHz in early window, got \(earlyFreq)")

        // Both independent tones contribute during the overlap.
        let overlap = Array(output[Int(2.2 * sr)..<Int(2.8 * sr)])
        #expect(rms(overlap) > 0.45)

        // After the mic ends, the delayed system tone must still be present.
        let late = Array(output[Int(3.5 * sr)..<Int(4.5 * sr)])
        #expect(abs(dominantFrequency(samples: late, sampleRate: sr) - 2000) < 10)
        #expect(rms(late) > 0.3)
        #expect(abs(Double(output.count) / sr - 5) < 0.1)
    }

    @Test("Silent mic → only sys audible")
    func silentMic() throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let micURL = dir.appendingPathComponent("audio.mic.caf")
        let sysURL = dir.appendingPathComponent("audio.sys.caf")
        let outURL = dir.appendingPathComponent("audio.m4a")

        try writeCaf(
            url: micURL,
            samples: silence(duration: 1.0, sampleRate: 48000),
            sampleRate: 48000
        )
        try writeCaf(
            url: sysURL,
            samples: sineWave(frequency: 1000, sampleRate: 48000, duration: 1.0, amplitude: 0.5),
            sampleRate: 48000
        )

        let mixer = AudioMixer()
        let timing = TimingMetadata(
            micStartEpoch: 0,
            sysStartEpoch: 0,
            sysDeclaredSampleRate: 48000,
            sysEffectiveSampleRate: 48000
        )
        try mixer.mix(micURL: micURL, sysURL: sysURL, timing: timing, outputURL: outURL)

        let output = try readSamples(at: outURL)
        let freq = dominantFrequency(samples: output, sampleRate: 48000)
        #expect(abs(freq - 1000) < 50)
    }

    @Test("Silent sys → only mic audible")
    func silentSys() throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let micURL = dir.appendingPathComponent("audio.mic.caf")
        let sysURL = dir.appendingPathComponent("audio.sys.caf")
        let outURL = dir.appendingPathComponent("audio.m4a")

        try writeCaf(
            url: micURL,
            samples: sineWave(frequency: 1000, sampleRate: 48000, duration: 1.0, amplitude: 0.5),
            sampleRate: 48000
        )
        try writeCaf(
            url: sysURL,
            samples: silence(duration: 1.0, sampleRate: 48000),
            sampleRate: 48000
        )

        let mixer = AudioMixer()
        let timing = TimingMetadata(
            micStartEpoch: 0,
            sysStartEpoch: 0,
            sysDeclaredSampleRate: 48000,
            sysEffectiveSampleRate: 48000
        )
        try mixer.mix(micURL: micURL, sysURL: sysURL, timing: timing, outputURL: outURL)

        let output = try readSamples(at: outURL)
        let freq = dominantFrequency(samples: output, sampleRate: 48000)
        #expect(abs(freq - 1000) < 50)
    }

    @Test("Missing mic file — mix succeeds with sys only")
    func missingMicFile() throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let micURL = dir.appendingPathComponent("audio.mic.caf") // never created
        let sysURL = dir.appendingPathComponent("audio.sys.caf")
        let outURL = dir.appendingPathComponent("audio.m4a")

        try writeCaf(
            url: sysURL,
            samples: sineWave(frequency: 1000, sampleRate: 48000, duration: 1.0, amplitude: 0.5),
            sampleRate: 48000
        )

        let mixer = AudioMixer()
        try mixer.mix(
            micURL: micURL,
            sysURL: sysURL,
            timing: TimingMetadata(
                sysStartEpoch: 0,
                sysDeclaredSampleRate: 48000,
                sysEffectiveSampleRate: 48000
            ),
            outputURL: outURL
        )

        let output = try readSamples(at: outURL)
        #expect(!output.isEmpty)
        let freq = dominantFrequency(samples: output, sampleRate: 48000)
        #expect(abs(freq - 1000) < 50)
    }

    @Test("Missing sys file — mix succeeds with mic only")
    func missingSysFile() throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let micURL = dir.appendingPathComponent("audio.mic.caf")
        let sysURL = dir.appendingPathComponent("audio.sys.caf") // never created
        let outURL = dir.appendingPathComponent("audio.m4a")

        try writeCaf(
            url: micURL,
            samples: sineWave(frequency: 800, sampleRate: 48000, duration: 1.0, amplitude: 0.5),
            sampleRate: 48000
        )

        let mixer = AudioMixer()
        try mixer.mix(
            micURL: micURL,
            sysURL: sysURL,
            timing: TimingMetadata(micStartEpoch: 0),
            outputURL: outURL
        )

        let output = try readSamples(at: outURL)
        #expect(!output.isEmpty)
        let freq = dominantFrequency(samples: output, sampleRate: 48000)
        #expect(abs(freq - 800) < 50)
    }

    @Test("Both missing — mix writes no output file")
    func bothMissing() throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let outURL = dir.appendingPathComponent("audio.m4a")

        let mixer = AudioMixer()
        try mixer.mix(
            micURL: dir.appendingPathComponent("audio.mic.caf"),
            sysURL: dir.appendingPathComponent("audio.sys.caf"),
            timing: TimingMetadata(),
            outputURL: outURL
        )

        #expect(!FileManager.default.fileExists(atPath: outURL.path))
    }

    @Test("44.1 kHz to 48 kHz resampling preserves tone frequency")
    func upsamplePreservesPitch() throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let micURL = dir.appendingPathComponent("audio.mic.caf")
        let sysURL = dir.appendingPathComponent("audio.sys.caf")
        let outURL = dir.appendingPathComponent("audio.m4a")

        // Check pitch after conversion; this does not measure spectral distortion.
        let tone = sineWave(frequency: 1000, sampleRate: 44100, duration: 2.0, amplitude: 0.6)
        try writeCaf(url: micURL, samples: tone, sampleRate: 44100)
        try writeCaf(
            url: sysURL,
            samples: silence(duration: 2.0, sampleRate: 48000),
            sampleRate: 48000
        )

        let mixer = AudioMixer()
        try mixer.mix(
            micURL: micURL,
            sysURL: sysURL,
            timing: TimingMetadata(
                micStartEpoch: 0,
                sysStartEpoch: 0,
                sysDeclaredSampleRate: 48000,
                sysEffectiveSampleRate: 48000
            ),
            outputURL: outURL
        )

        let output = try readSamples(at: outURL)
        let skip = Int(0.05 * 48000) // skip AAC priming
        let freq = dominantFrequency(
            samples: Array(output.dropFirst(skip)),
            sampleRate: 48000
        )
        #expect(abs(freq - 1000) < 5, "Expected ~1 kHz after 44.1→48 kHz upsample, got \(freq)")
    }

    @Test("Five-minute recording preserves output duration")
    func longRecordingPreservesDuration() throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let micURL = dir.appendingPathComponent("audio.mic.caf")
        let sysURL = dir.appendingPathComponent("audio.sys.caf")
        let outURL = dir.appendingPathComponent("audio.m4a")

        let duration = 300.0
        try writeCaf(
            url: micURL,
            samples: sineWave(frequency: 440, sampleRate: 48000, duration: duration, amplitude: 0.4),
            sampleRate: 48000
        )
        try writeCaf(
            url: sysURL,
            samples: sineWave(frequency: 880, sampleRate: 48000, duration: duration, amplitude: 0.4),
            sampleRate: 48000
        )

        let mixer = AudioMixer()
        try mixer.mix(
            micURL: micURL,
            sysURL: sysURL,
            timing: TimingMetadata(
                micStartEpoch: 0,
                sysStartEpoch: 0,
                sysDeclaredSampleRate: 48000,
                sysEffectiveSampleRate: 48000
            ),
            outputURL: outURL
        )
        let file = try AVAudioFile(forReading: outURL)
        let actualDuration = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(actualDuration - duration) < 0.1)
    }
}
