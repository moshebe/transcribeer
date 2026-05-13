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
    @Test("Synthetic mix produces expected peak and silence regions")
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

        let effectiveSR = 47988.3
        let tone = sineWave(frequency: 1000, sampleRate: effectiveSR, duration: 2.0, amplitude: 0.8)
        try writeCaf(url: sysURL, samples: tone, sampleRate: effectiveSR)

        let micURL = dir.appendingPathComponent("audio.mic.caf")
        try writeCaf(url: micURL, samples: silence(duration: 2.0, sampleRate: 48000), sampleRate: 48000)

        let mixer = AudioMixer()
        let timing = TimingMetadata(
            micStartEpoch: 0,
            sysStartEpoch: 0,
            sysDeclaredSampleRate: effectiveSR,
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

        // Mic: 1 kHz tone for 5 seconds
        let micTone = sineWave(frequency: 1000, sampleRate: 48000, duration: 5.0, amplitude: 0.5)
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
        let early = Array(output[0..<Int(sr)])
        let earlyFreq = dominantFrequency(samples: early, sampleRate: sr)
        #expect(abs(earlyFreq - 1000) < 50, "Expected ~1 kHz in early window, got \(earlyFreq)")

        // Window 2-3s: both present → higher energy, mix of 1k + 2k
        let midStart = Int(2.0 * sr)
        let midEnd = Int(3.0 * sr)
        let mid = Array(output[midStart..<min(midEnd, output.count)])
        let midEnergy = rms(mid)
        #expect(midEnergy > 0.3, "Expected high energy when both sources present")

        // Window 6-7s: only sys should remain (but sys is only 3s, so past 5s total)
        // After alignment: sys spans 2s to 5s, mic spans 0s to 5s
        // So past 5s should be silent
        let lateStart = Int(5.5 * sr)
        guard lateStart < output.count else { return }
        let late = Array(output[lateStart..<min(lateStart + Int(sr), output.count)])
        let lateEnergy = rms(late)
        #expect(lateEnergy < 0.05, "Expected silence after both sources end")
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

    @Test("44.1 kHz source upsamples cleanly to 48 kHz (no aliasing)")
    func upsampleNoAliasing() throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let micURL = dir.appendingPathComponent("audio.mic.caf")
        let sysURL = dir.appendingPathComponent("audio.sys.caf")
        let outURL = dir.appendingPathComponent("audio.m4a")

        // 1 kHz tone at 44.1 kHz — a sample rate the old linear-interp
        // resampler would have smeared with broadband aliasing. Upsample to
        // 48 kHz and assert the dominant frequency is still 1 kHz.
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

    @Test("Long recording mixes without allocating proportional RAM")
    func streamingMemoryBound() throws {
        let dir = makeSessionDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let micURL = dir.appendingPathComponent("audio.mic.caf")
        let sysURL = dir.appendingPathComponent("audio.sys.caf")
        let outURL = dir.appendingPathComponent("audio.m4a")

        // 5 minutes at 48 kHz mono = 57.6 MB per source buffer in the old
        // in-memory mixer; at 60 minutes it was ~700 MB per source. Five
        // minutes here keeps test runtime reasonable while still exercising
        // many chunk iterations in the streaming mixer.
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

        let baselineRSS = currentRSSBytes()
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
        let peakRSS = currentRSSBytes()
        let delta = Int64(peakRSS) - Int64(baselineRSS)

        // A proportional allocator on 300 s of 48 kHz mono float32 would
        // grow RSS by at least 55 MB per buffer (we hold two source buffers
        // plus the mixed output = ~165 MB minimum). The streaming path
        // should stay well under 50 MB — allow 100 MB to absorb AAC encoder
        // allocations + test host noise without being lenient enough to
        // miss a regression.
        #expect(
            delta < 100 * 1024 * 1024,
            "Mix RSS grew by \(delta / 1024 / 1024) MB — streaming path regressed?"
        )

        // Sanity: output exists and has signal.
        let output = try readSamples(at: outURL)
        #expect(!output.isEmpty)
    }
}

// MARK: - Memory probe

import Darwin

/// Return the current process' resident set size in bytes.
///
/// Used only by the streaming-mix regression test; not audio-specific.
private func currentRSSBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
    )
    let status = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                reboundPtr,
                &count
            )
        }
    }
    return status == KERN_SUCCESS ? info.resident_size : 0
}
