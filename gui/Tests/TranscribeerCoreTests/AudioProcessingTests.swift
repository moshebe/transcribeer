import Foundation
import Testing
@testable import TranscribeerCore

struct AudioProcessingTests {
    @Test("Transcode request defaults match sidecar compression target")
    func transcodeRequestDefaults() {
        let request = AudioTranscodeRequest(
            inputURL: URL(fileURLWithPath: "/tmp/input.caf"),
            outputURL: URL(fileURLWithPath: "/tmp/output.m4a")
        )

        #expect(request.codec == .aac)
        #expect(request.container == .m4a)
        #expect(request.container.fileExtension == "m4a")
        #expect(request.channelMode == .mono)
        #expect(request.channelMode.channelCount == 1)
        #expect(request.sampleRate == 16_000)
        #expect(request.bitrate == 48_000)
    }

    @Test("Channel modes expose backend channel counts")
    func channelModesExposeCounts() {
        #expect(AudioProcessingChannelMode.preserve.channelCount == nil)
        #expect(AudioProcessingChannelMode.mono.channelCount == 1)
        #expect(AudioProcessingChannelMode.stereo.channelCount == 2)
    }

    @Test("Backend availability factories preserve probe details")
    func backendAvailabilityFactories() {
        let executable = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        let available = AudioProcessingBackendAvailability.available(
            backendID: "ffmpeg",
            executableURL: executable
        )
        let unavailable = AudioProcessingBackendAvailability.unavailable(
            backendID: "ffmpeg",
            reason: "binary not found"
        )

        #expect(available.isAvailable)
        #expect(available.executableURL == executable)
        #expect(available.reason == nil)
        #expect(unavailable.isAvailable == false)
        #expect(unavailable.reason == "binary not found")
    }

    @Test("Audio processing errors have user-facing descriptions")
    func errorDescriptions() {
        let unavailable = AudioProcessingBackendAvailability.unavailable(
            backendID: "ffmpeg",
            reason: "binary not found"
        )
        let output = URL(fileURLWithPath: "/tmp/audio.mic.m4a")

        #expect(
            AudioProcessingError.backendUnavailable(unavailable).errorDescription ==
                "ffmpeg audio backend is unavailable: binary not found"
        )
        #expect(
            AudioProcessingError.cannotCreateExporter(backendID: "avfoundation").errorDescription ==
                "avfoundation cannot create an audio exporter for this request"
        )
        #expect(
            AudioProcessingError.emptyOutput(output).errorDescription ==
                "Audio processing produced an empty output file: audio.mic.m4a"
        )
        #expect(
            AudioProcessingError.outputReplacementFailed(
                outputURL: output,
                message: "permission denied"
            ).errorDescription == "Could not replace output audio file audio.mic.m4a: permission denied"
        )
        #expect(
            AudioProcessingError.commandFailed(
                backendID: "ffmpeg",
                exitCode: 1,
                message: "invalid data"
            ).errorDescription == "ffmpeg audio command failed with exit code 1: invalid data"
        )
    }
}
