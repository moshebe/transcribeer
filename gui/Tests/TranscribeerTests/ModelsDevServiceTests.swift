import Foundation
import Testing
@testable import TranscribeerApp

@MainActor
struct ModelsDevServiceTests {
    @Test("Downloaded catalog filters and orders model menus, then serves them from the disk cache")
    func refreshAndCache() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        try fixture.respond(with: catalog)
        let service = fixture.service()

        await service.refreshIfStale()

        #expect(service.summaryModels(for: .openai) == ["gpt-new", "gpt-older"])
        #expect(service.summaryModels(for: .anthropic) == ["claude-test"])
        #expect(service.summaryModels(for: .gemini) == ["gemini-vertex"])
        #expect(service.geminiTranscriptionModels == ["gemini-audio"])
        #expect(service.chatPricing(for: "gpt-new") == ChatModelPricing(inputPerMillion: 2, outputPerMillion: 10))

        // A new response would replace the menu if the fresh cache were ignored.
        try fixture.respond(with: replacement)
        let reopened = fixture.service()
        await reopened.refreshIfStale()
        #expect(reopened.summaryModels(for: .openai) == ["gpt-new", "gpt-older"])
        #expect(reopened.summaryModels(for: .anthropic) == ["claude-test"])
    }

    @Test("A failed or empty refresh preserves the old menu and cache", arguments: [
        (500, "server error"),
        (200, #"{"unrelated":{}}"#),
        (200, #"{"openai":{"models":{}}}"#),
        (200, #"{"openai":{"models":{"old":{"status":"deprecated"}}}}"#),
    ])
    func failedRefreshKeepsCache(status: Int, response: String) async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        try fixture.respond(with: catalog)
        await fixture.service().refreshIfStale()
        let saved = try Data(contentsOf: fixture.cacheURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.distantPast], ofItemAtPath: fixture.cacheURL.path
        )
        try fixture.respond(with: response)

        let reopened = fixture.service(status: status)
        await reopened.refreshIfStale()

        #expect(reopened.summaryModels(for: .openai) == ["gpt-new", "gpt-older"])
        #expect(try Data(contentsOf: fixture.cacheURL) == saved)
    }

    @Test("Empty providers remain absent after downloading and reopening a partial catalog")
    func emptyProvidersUseFallback() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        try fixture.respond(with: #"""
        {
          "openai":{"models":{}},
          "anthropic":{"models":{"claude-test":{"modalities":{"input":["text"],"output":["text"]}}}},
          "google-vertex":{"models":{"gemini-missing-modalities":{}}},
          "google":{"models":{"gemini-text-only":{"modalities":{"input":["text"],"output":["text"]}}}}
        }
        """#)
        let service = fixture.service()
        await service.refreshIfStale()
        #expect(service.summaryModels(for: .openai) == nil)
        #expect(service.summaryModels(for: .gemini) == nil)
        #expect(service.geminiTranscriptionModels == nil)
        #expect(service.summaryModels(for: .anthropic) == ["claude-test"])

        try fixture.respond(with: replacement)
        let reopened = fixture.service()
        await reopened.refreshIfStale()
        #expect(reopened.summaryModels(for: .openai) == nil)
        #expect(reopened.geminiTranscriptionModels == nil)
        #expect(reopened.summaryModels(for: .anthropic) == ["claude-test"])
    }

    @Test("A malformed first response does not create a cache and a later retry can recover")
    func retryAfterBadResponse() async throws {
        let fixture = try CatalogFixture()
        defer { fixture.remove() }
        try fixture.respond(with: "not JSON")
        let service = fixture.service()
        await service.refreshIfStale()
        #expect(service.summaryModels(for: .openai) == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.cacheURL.path) == false)

        try fixture.respond(with: replacement)
        await service.refreshIfStale()
        #expect(service.summaryModels(for: .openai) == ["gpt-replacement"])
        #expect(FileManager.default.fileExists(atPath: fixture.cacheURL.path))
    }

    private var replacement: String {
        #"{"openai":{"models":{"gpt-replacement":{"modalities":{"input":["text"],"output":["text"]}}}}}"#
    }

    private var catalog: String {
        #"""
        {
          "reseller":{"models":{"gpt-new":{"cost":{"input":99,"output":99}}}},
          "openai":{"models":{
            "gpt-older":{"release_date":"2025-01-01","modalities":{"input":["text"],"output":["text"]}},
            "gpt-new":{"release_date":"2026-01-01","cost":{"input":2,"output":10},
              "modalities":{"input":["text","image"],"output":["text"]}},
            "gpt-image":{"modalities":{"input":["text"],"output":["text","image"]}},
            "text-embedding":{"modalities":{"input":["text"],"output":["text"]}},
            "gpt-retired":{"status":"deprecated","modalities":{"input":["text"],"output":["text"]}},
            "gpt-pro":{"modalities":{"input":["text"],"output":["text"]}},
            "gpt-codex":{"modalities":{"input":["text"],"output":["text"]}}
          }},
          "anthropic":{"models":{"claude-test":{"modalities":{"input":["text"],"output":["text"]}}}},
          "google-vertex":{"models":{
            "gemini-vertex":{"modalities":{"input":["text"],"output":["text"]}},
            "claude-vertex":{"modalities":{"input":["text"],"output":["text"]}}
          }},
          "google":{"models":{
            "gemini-audio":{"modalities":{"input":["audio","text"],"output":["text"]}},
            "gemini-text":{"modalities":{"input":["text"],"output":["text"]}},
            "gemini-realtime":{"modalities":{"input":["text","audio"],"output":["text"]}}
          }}
        }
        """#
    }
}

@MainActor
private struct CatalogFixture {
    let directory: URL
    let cacheURL: URL
    let responseURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cacheURL = directory.appendingPathComponent("cache/models.json")
        responseURL = directory.appendingPathComponent("response.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func service(status: Int = 200) -> ModelsDevService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        configuration.httpAdditionalHeaders = [
            "X-Fixture-Path": responseURL.path,
            "X-Fixture-Status": String(status),
        ]
        return ModelsDevService(cacheURL: cacheURL, session: URLSession(configuration: configuration))
    }

    func respond(with json: String) throws { try Data(json.utf8).write(to: responseURL) }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class CatalogURLProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let path = request.value(forHTTPHeaderField: "X-Fixture-Path"),
                  let status = request.value(forHTTPHeaderField: "X-Fixture-Status").flatMap(Int.init),
                  let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            else { throw URLError(.badServerResponse) }
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
