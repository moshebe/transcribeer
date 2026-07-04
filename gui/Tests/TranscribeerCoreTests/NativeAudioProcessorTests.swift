import AVFoundation
import Foundation
import Testing
@testable import TranscribeerCore

struct NativeAudioProcessorTests {
    @Test("Availability reports native AVFoundation backend")
    func availabilityReportsNativeBackend() async {
        let availability = await NativeAudioProcessor().availability()

        #expect(availability.backendID == "avfoundation")
        #expect(availability.isAvailable)
        #expect(availability.executableURL == nil)
        #expect(availability.reason == nil)
    }

    @Test("Native processor transcodes generated CAF fixture to non-empty M4A")
    func transcodesGeneratedCAFToM4A() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("audio.mic.caf")
        let output = directory.appendingPathComponent("audio.mic.m4a")
        try writeCAFFixture(to: input)

        let request = AudioTranscodeRequest(inputURL: input, outputURL: output)
        let result = try await NativeAudioProcessor().transcode(request)
        let outputFile = try AVAudioFile(forReading: output)

        #expect(SourceAudioFiles.isNonEmpty(output))
        #expect(result.outputURL == output)
        #expect(result.backendID == "avfoundation")
        #expect(result.outputBytes > 0)
        #expect(result.inputBytes == fileSize(input))
        #expect(result.durationSeconds ?? 0 > 0)
        #expect(outputFile.length > 0)
    }

    @Test("Native processor rejects missing input with domain error")
    func missingInputUsesDomainError() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("missing.caf")
        let output = directory.appendingPathComponent("output.m4a")

        let request = AudioTranscodeRequest(inputURL: input, outputURL: output)
        await #expect(throws: AudioProcessingError.inputMissing(input)) {
            try await NativeAudioProcessor().transcode(request)
        }
    }
}

private func writeCAFFixture(to url: URL) throws {
    let sampleRate = 44_100.0
    let durationSeconds = 0.25
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 2,
        interleaved: false
    ) else {
        throw AudioFixtureError.formatSetupFailed
    }
    let frames = AVAudioFrameCount(sampleRate * durationSeconds)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
        throw AudioFixtureError.bufferAllocFailed
    }
    buffer.frameLength = frames
    try fillSineWave(buffer: buffer, sampleRate: sampleRate)

    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: Int(format.channelCount),
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    try file.write(from: buffer)
}

private func fillSineWave(buffer: AVAudioPCMBuffer, sampleRate: Double) throws {
    guard let channels = buffer.floatChannelData else {
        throw AudioFixtureError.bufferAllocFailed
    }
    for channelIndex in 0..<Int(buffer.format.channelCount) {
        let samples = channels[channelIndex]
        for frameIndex in 0..<Int(buffer.frameLength) {
            let phase = 2.0 * Double.pi * 440.0 * Double(frameIndex) / sampleRate
            samples[frameIndex] = Float(sin(phase) * 0.2)
        }
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAudioProcessorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func fileSize(_ url: URL) -> UInt64 {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
        return 0
    }
    return switch attributes[.size] {
    case let size as UInt64: size
    case let size as NSNumber: size.uint64Value
    default: 0
    }
}

private enum AudioFixtureError: Error {
    case formatSetupFailed
    case bufferAllocFailed
}
