import AVFoundation
import Darwin
import Foundation
import Testing
@testable import CaptureCore

struct AudioMixerMemoryTests {
    @Test("Ten-minute mixing stays below a 100 MiB increase in peak memory", .timeLimit(.minutes(1)))
    func peakMemoryIsBounded() async {
        await #expect(processExitsWith: .success) {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let mic = directory.appendingPathComponent("mic.caf")
            let sys = directory.appendingPathComponent("sys.caf")
            let output = directory.appendingPathComponent("mixed.m4a")
            try writeStreamingFixture(to: mic)
            try FileManager.default.copyItem(at: mic, to: sys)

            let baseline = try peakMemory()
            try AudioMixer().mix(
                micURL: mic,
                sysURL: sys,
                timing: TimingMetadata(
                    micStartEpoch: 0,
                    sysStartEpoch: 0,
                    sysDeclaredSampleRate: 48_000,
                    sysEffectiveSampleRate: 48_000
                ),
                outputURL: output
            )
            let increase = try peakMemory() - baseline
            #expect(increase < 100 * 1024 * 1024, "Mixing increased peak memory by \(increase) bytes")
            let file = try AVAudioFile(forReading: output)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            #expect(abs(duration - 600) < 0.1, "The memory check must process the entire recording")
        }
    }
}

private func peakMemory() throws -> Int {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return usage.ru_maxrss
}

private func writeStreamingFixture(to url: URL) throws {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
    ))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
    buffer.frameLength = 16_000
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0..<16_000 {
        samples[index] = 0.2 * Float(sin(2 * .pi * 440 * Double(index) / 48_000))
    }
    for _ in 0..<1_800 {
        try file.write(from: buffer)
    }
}
