import AVFoundation
import Foundation
import os
import Testing
@testable import TranscribeerApp

struct OpenAITranscriptionRequestTests {
    @Test("Transcription sends model-specific options and preserves audio duration", .serialized, arguments: [
        ("gpt-transcribe", "he", "languages[]", false),
        ("gpt-transcribe", nil, nil, false),
        ("gpt-4o-transcribe", "en", "language", false),
        ("whisper-1", "he", "language", true),
    ])
    func requestOptions(model: String, language: String?, field: String?, timestamps: Bool) async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("request-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try writeAudio(to: audioURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranscriptionRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        TranscriptionRequestProtocol.captured.withLock { $0 = nil }

        let segments = try await OpenAITranscription.call(
            audioURL: audioURL, model: model, language: language, apiKey: "test-key", session: session
        )
        let request = try #require(TranscriptionRequestProtocol.captured.withLock { $0 })
        #expect(request.url?.path == "/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        let data = try #require(request.httpBody)
        let body = try #require(String(data: data, encoding: .isoLatin1))
        #expect(body.contains("name=\"model\"\r\n\r\n\(model)\r\n"))
        #expect(body.contains("name=\"timestamp_granularities[]\"") == timestamps)
        #expect(body.contains("verbose_json") == timestamps)
        if let field, let language {
            #expect(body.contains("name=\"\(field)\"\r\n\r\n\(language)\r\n"))
        } else {
            #expect(body.contains("name=\"language") == false)
        }
        #expect(segments.count == 1)
        let segment = try #require(segments.first)
        #expect(segment.text == "A short meeting.")
        #expect(abs(segment.end - 2) < 0.1)
    }

    private func writeAudio(to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 48_000,
        ])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_000))
        buffer.frameLength = 32_000
        try file.write(from: buffer)
    }

    @Test("Response timing does not require reopening the uploaded audio", arguments: [
        (#"{"text":"Meeting","duration":12}"#, 12.0),
        (#"{"segments":[{"text":"Meeting","start":2,"end":7}]}"#, 7.0),
        (#"{"text":""}"#, nil),
    ])
    func responseTiming(response: String, expectedEnd: Double?) async throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        try writeAudio(to: audioURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranscriptionRequestProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Response": response, "X-Remove-Audio": audioURL.path]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let segments = try await OpenAITranscription.call(
            audioURL: audioURL, model: "gpt-transcribe", language: nil, apiKey: "test-key", session: session
        )
        #expect(!FileManager.default.fileExists(atPath: audioURL.path))
        #expect(segments.last?.end == expectedEnd)
        #expect(segments.count == (expectedEnd == nil ? 0 : 1))
    }
}

private final class TranscriptionRequestProtocol: URLProtocol, @unchecked Sendable {
    static let captured = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            recorded.httpBody = body
        }
        let snapshot = recorded
        if request.value(forHTTPHeaderField: "X-Response") == nil {
            Self.captured.withLock { $0 = snapshot }
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if let path = request.value(forHTTPHeaderField: "X-Remove-Audio") {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
        }
        let json = request.value(forHTTPHeaderField: "X-Response") ?? #"{"text":"A short meeting."}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
