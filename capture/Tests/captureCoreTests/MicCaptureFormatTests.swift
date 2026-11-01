import AVFoundation
import Testing
@testable import CaptureCore

struct MicCaptureFormatTests {
    @Test("Valid tap formats keep the audio stream open", arguments: [
        (48_000.0, UInt32(1)),
        (44_100.0, UInt32(2)),
        (24_000.0, UInt32(1)),
        (16_000.0, UInt32(1)),
        (96_000.0, UInt32(1)),
    ])
    func acceptsValidFormat(sampleRate: Double, channels: UInt32) async throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ))
        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        defer { continuation.finish() }
        let error = SyncString()

        #expect(MicCapture.validateTapFormat(format, errorHolder: error, continuation: continuation))
        #expect(error.value == nil)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        continuation.yield(buffer)
        continuation.finish()
        var iterator = stream.makeAsyncIterator()
        let received = try #require(await iterator.next())
        #expect(received.format.sampleRate == sampleRate)
        #expect(received.format.channelCount == channels)
    }

    @Test("Invalid tap formats report an error and finish the audio stream", arguments: [
        (48_000.0, UInt32(0)),
        (0.0, UInt32(1)),
    ])
    func rejectsInvalidFormat(sampleRate: Double, channels: UInt32) async throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channels * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: channels * 4,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let format = try #require(AVAudioFormat(streamDescription: &description))
        let (stream, continuation) = AsyncStream.makeStream(of: AVAudioPCMBuffer.self)
        let error = SyncString()

        #expect(MicCapture.validateTapFormat(format, errorHolder: error, continuation: continuation) == false)
        #expect(error.value?.contains("invalid audio format") == true)
        // A missing finish must fail here instead of hanging the test.
        let validFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: validFormat, frameCapacity: 1))
        guard case .terminated = continuation.yield(buffer) else {
            Issue.record("Invalid format left the stream open")
            continuation.finish()
            return
        }
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}
