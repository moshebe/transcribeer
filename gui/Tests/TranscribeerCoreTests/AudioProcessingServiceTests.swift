import Foundation
import Testing
@testable import TranscribeerCore

struct AudioProcessingServiceTests {
    @Test("ffmpeg success returns immediately without touching fallback")
    func ffmpegSuccessSkipsFallback() async throws {
        let request = makeRequest()
        let ffmpeg = AudioBackendStub(
            backendID: "ffmpeg",
            outcome: .success(makeResult(backendID: "ffmpeg", outputURL: request.outputURL))
        )
        let native = AudioBackendStub(
            backendID: "avfoundation",
            outcome: .success(makeResult(backendID: "avfoundation", outputURL: request.outputURL))
        )
        let service = AudioProcessingService(backends: [ffmpeg, native])

        let result = try await service.transcode(request)

        #expect(result.backendID == "ffmpeg")
        #expect(await ffmpeg.calls() == BackendCalls(availability: 1, transcode: 1))
        #expect(await native.calls() == BackendCalls(availability: 0, transcode: 0))
    }

    @Test("missing ffmpeg falls back to native backend")
    func missingFFmpegFallsBackToNative() async throws {
        let request = makeRequest()
        let ffmpeg = AudioBackendStub(
            backendID: "ffmpeg",
            availability: .unavailable(backendID: "ffmpeg", reason: "binary not found"),
            outcome: .failure(.backendUnavailable(.unavailable(backendID: "ffmpeg", reason: "binary not found")))
        )
        let native = AudioBackendStub(
            backendID: "avfoundation",
            outcome: .success(makeResult(backendID: "avfoundation", outputURL: request.outputURL))
        )
        let service = AudioProcessingService(backends: [ffmpeg, native])

        let result = try await service.transcode(request)

        #expect(result.backendID == "avfoundation")
        #expect(await ffmpeg.calls() == BackendCalls(availability: 1, transcode: 0))
        #expect(await native.calls() == BackendCalls(availability: 1, transcode: 1))
    }

    @Test("failing ffmpeg falls back to native backend")
    func failingFFmpegFallsBackToNative() async throws {
        let request = makeRequest()
        let ffmpeg = AudioBackendStub(
            backendID: "ffmpeg",
            outcome: .failure(.commandFailed(backendID: "ffmpeg", exitCode: 1, message: "decode failed"))
        )
        let native = AudioBackendStub(
            backendID: "avfoundation",
            outcome: .success(makeResult(backendID: "avfoundation", outputURL: request.outputURL))
        )
        let service = AudioProcessingService(backends: [ffmpeg, native])

        let result = try await service.transcode(request)

        #expect(result.backendID == "avfoundation")
        #expect(await ffmpeg.calls() == BackendCalls(availability: 1, transcode: 1))
        #expect(await native.calls() == BackendCalls(availability: 1, transcode: 1))
    }

    @Test("all backend failures preserve useful error details")
    func allBackendFailuresAreReported() async throws {
        let request = makeRequest()
        let ffmpeg = AudioBackendStub(
            backendID: "ffmpeg",
            outcome: .failure(.commandFailed(backendID: "ffmpeg", exitCode: 7, message: "decode failed"))
        )
        let native = AudioBackendStub(
            backendID: "avfoundation",
            outcome: .failure(.exportFailed(backendID: "avfoundation", message: "codec rejected"))
        )
        let service = AudioProcessingService(backends: [ffmpeg, native])

        do {
            _ = try await service.transcode(request)
            Issue.record("Expected allBackendsFailed")
        } catch let error as AudioProcessingError {
            guard case let .allBackendsFailed(failures) = error else {
                Issue.record("Expected allBackendsFailed, got \(error)")
                return
            }
            let firstFailure = try #require(failures.first)
            let secondFailure = try #require(failures.dropFirst().first)
            #expect(failures.map(\.backendID) == ["ffmpeg", "avfoundation"])
            #expect(firstFailure.message.contains("decode failed"))
            #expect(secondFailure.message.contains("codec rejected"))
            #expect(error.localizedDescription.contains("All audio processing backends failed"))
        }
    }
}

private actor AudioBackendStub: AudioProcessingBackend {
    nonisolated let backendID: String

    private let availabilityResult: AudioProcessingBackendAvailability
    private let outcome: AudioBackendOutcome
    private var availabilityCallCount = 0
    private var transcodeCallCount = 0

    init(
        backendID: String,
        availability: AudioProcessingBackendAvailability? = nil,
        outcome: AudioBackendOutcome
    ) {
        self.backendID = backendID
        self.availabilityResult = availability ?? .available(backendID: backendID)
        self.outcome = outcome
    }

    func availability() async -> AudioProcessingBackendAvailability {
        availabilityCallCount += 1
        return availabilityResult
    }

    func transcode(_ request: AudioTranscodeRequest) async throws -> AudioTranscodeResult {
        transcodeCallCount += 1
        return switch outcome {
        case let .success(result): result
        case let .failure(error): throw error
        }
    }

    func calls() -> BackendCalls {
        BackendCalls(availability: availabilityCallCount, transcode: transcodeCallCount)
    }
}

private struct BackendCalls: Equatable {
    let availability: Int
    let transcode: Int
}

private enum AudioBackendOutcome: Sendable {
    case success(AudioTranscodeResult)
    case failure(AudioProcessingError)
}

private func makeRequest() -> AudioTranscodeRequest {
    AudioTranscodeRequest(
        inputURL: URL(fileURLWithPath: "/tmp/input.caf"),
        outputURL: URL(fileURLWithPath: "/tmp/output.m4a")
    )
}

private func makeResult(backendID: String, outputURL: URL) -> AudioTranscodeResult {
    AudioTranscodeResult(outputURL: outputURL, backendID: backendID, outputBytes: 100)
}
