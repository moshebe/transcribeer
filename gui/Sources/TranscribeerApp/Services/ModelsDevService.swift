import Foundation
import Observation
import os.log

/// Shared models.dev cache for model menus and price estimates.
@MainActor
@Observable
final class ModelsDevService {
    static let shared = ModelsDevService()

    private static let endpoint = URL(string: "https://models.dev/api.json")
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    private let cacheURL: URL
    private let session: URLSession
    private let logger = Logger(subsystem: "com.transcribeer", category: "model-catalog")
    private var snapshot = ModelsDevSnapshot()
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var updatedAt: Date?

    init(
        cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/cache/models-dev.json"),
        session: URLSession = .shared
    ) {
        self.cacheURL = cacheURL
        self.session = session
    }

    func chatPricing(for model: String) -> ChatModelPricing? {
        snapshot.pricing[model] ?? snapshot.pricing[model.lowercased()]
    }

    func summaryModels(for backend: LLMBackend) -> [String]? {
        snapshot.summaryModels[backend]
    }

    var geminiTranscriptionModels: [String]? { snapshot.geminiTranscriptionModels }

    /// Views observe the snapshot, including when another caller owns the refresh.
    func refreshIfStale() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let cacheURL = cacheURL
        if !loaded {
            let cached = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: cacheURL),
                      let parsed = try? ModelsDevSnapshot(data: data) else { return nil as (ModelsDevSnapshot, Date?)? }
                let values = try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey])
                return (parsed, values?.contentModificationDate)
            }.value
            if let cached {
                snapshot = cached.0
                updatedAt = cached.1
            }
            loaded = true
        }
        if let updatedAt, Date().timeIntervalSince(updatedAt) < Self.maxAge { return }
        guard let endpoint = Self.endpoint else { return }
        do {
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let parsed = try await Task.detached(priority: .utility) {
                try ModelsDevSnapshot(data: data)
            }.value
            try Task.checkCancellation()
            snapshot = parsed
            updatedAt = Date()
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try data.write(to: cacheURL, options: .atomic)
            }.value
            logger.info("models.dev cache refreshed")
        } catch {
            logger.warning("models.dev refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Per-million-token cost in USD for a single chat model.
struct ChatModelPricing: Equatable, Sendable {
    let inputPerMillion: Double
    let outputPerMillion: Double
}
