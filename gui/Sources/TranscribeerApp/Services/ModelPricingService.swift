import Foundation
import os.log

/// Pulls chat-model pricing from <https://models.dev/api.json> and caches it
/// on disk so the per-session "cost" badge stays current without bundling a
/// price table that goes stale within months.
///
/// The service exposes a *synchronous* lookup backed by an in-memory snapshot
/// hydrated from the on-disk cache at first access. A background refresh
/// (`refreshIfStale()`) re-fetches once a week — fire-and-forget from app
/// launch. Failures are silently logged because cost display is best-effort:
/// callers fall back to `PricingCatalog`'s hardcoded fallback table when no
/// network/disk snapshot is available.
@MainActor
final class ModelPricingService {
    static let shared = ModelPricingService()

    /// Source of truth for chat-model pricing. JSON is `{<provider>:
    /// {models: {<id>: {cost: {input, output}}}}}` — we flatten to model id.
    private static let endpoint = URL(string: "https://models.dev/api.json")

    /// Refresh the disk cache when it's older than this. A week balances
    /// "freshness if prices change" against "don't hammer models.dev every
    /// launch".
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    private let cacheURL: URL
    private let logger = Logger(subsystem: "com.transcribeer", category: "pricing")
    private var snapshot: [String: ChatModelPricing] = [:]
    private var loaded = false

    private init(
        cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/cache/models-dev.json"),
    ) {
        self.cacheURL = cacheURL
    }

    /// Per-million-token input/output cost in USD. `nil` when the model
    /// isn't in the most recent snapshot.
    func chatPricing(for model: String) -> ChatModelPricing? {
        ensureLoaded()
        if let exact = snapshot[model] { return exact }
        // models.dev keys are case-sensitive; the local catalog uses both
        // canonical (`gpt-4o`) and dated (`gpt-4o-2024-05-13`) ids.
        return snapshot[model.lowercased()]
    }

    /// Refetch the catalog when the cache is older than `maxAge`. Safe to
    /// call from any context — it spawns a Task internally and never
    /// throws. Intended to be invoked once at app launch.
    func refreshIfStale() {
        Task { [weak self] in
            await self?.refreshIfStaleAsync()
        }
    }

    // MARK: - Internals

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        snapshot = readCachedSnapshot() ?? [:]
    }

    private func refreshIfStaleAsync() async {
        ensureLoaded()
        if !isStale { return }
        guard let endpoint = Self.endpoint else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: endpoint)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                logger.warning("models.dev fetch HTTP \(http.statusCode, privacy: .public)")
                return
            }
            let parsed = try parseSnapshot(from: data)
            try persist(rawJSON: data)
            snapshot = parsed
            logger.info("models.dev cache refreshed: \(parsed.count, privacy: .public) entries")
        } catch {
            logger.warning(
                "models.dev refresh failed: \(error.localizedDescription, privacy: .public)",
            )
        }
    }

    private var isStale: Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: cacheURL.path),
              let modified = attrs[.modificationDate] as? Date
        else { return true }
        return Date().timeIntervalSince(modified) >= Self.maxAge
    }

    private func readCachedSnapshot() -> [String: ChatModelPricing]? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? parseSnapshot(from: data)
    }

    private func persist(rawJSON: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try rawJSON.write(to: cacheURL, options: .atomic)
    }

    /// Flatten the models.dev shape into `[modelId: ChatModelPricing]`.
    /// Entries without numeric input/output cost are skipped — some models
    /// (image, embedding) have non-token pricing we can't use here.
    private func parseSnapshot(from data: Data) throws -> [String: ChatModelPricing] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PricingError.invalidPayload
        }
        var out: [String: ChatModelPricing] = [:]
        for (_, providerValue) in root {
            guard let provider = providerValue as? [String: Any],
                  let models = provider["models"] as? [String: Any]
            else { continue }
            for (modelID, modelValue) in models {
                guard let model = modelValue as? [String: Any],
                      let cost = model["cost"] as? [String: Any],
                      let input = numericValue(cost["input"]),
                      let output = numericValue(cost["output"])
                else { continue }
                out[modelID] = ChatModelPricing(
                    inputPerMillion: input,
                    outputPerMillion: output,
                )
            }
        }
        return out
    }

    private func numericValue(_ raw: Any?) -> Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let string = raw as? String { return Double(string) }
        return nil
    }

    enum PricingError: Error { case invalidPayload }
}

/// Per-million-token cost in USD for a single chat model.
struct ChatModelPricing: Equatable, Sendable {
    let inputPerMillion: Double
    let outputPerMillion: Double
}
