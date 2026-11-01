import AVFoundation
import Testing
@testable import CaptureCore

struct MicCaptureFormatTests {
    @Test("Valid tap formats are accepted", arguments: [
        (48_000.0, UInt32(1)),
        (44_100.0, UInt32(2)),
        (24_000.0, UInt32(1)),
        (16_000.0, UInt32(1)),
        (96_000.0, UInt32(1)),
    ])
    func acceptsValidFormat(sampleRate: Double, channels: UInt32) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ))

        #expect(MicCapture.validateTapFormat(format) == nil)
    }

    @Test("Invalid tap formats report a user-facing error", arguments: [
        (48_000.0, UInt32(0)),
        (0.0, UInt32(1)),
    ])
    func rejectsInvalidFormat(sampleRate: Double, channels: UInt32) throws {
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

        let error = MicCapture.validateTapFormat(format)
        #expect(error?.contains("invalid audio format") == true)
    }
}
