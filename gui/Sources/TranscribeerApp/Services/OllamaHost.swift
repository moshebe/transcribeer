import Foundation

/// Normalizes the Ollama host the user typed, so the summary client, the model
/// list and the Settings probe all call the same base URL.
enum OllamaHost {
    /// The bare host URL, without a trailing `/` or `/v1`. The LLM package
    /// appends `v1/chat/completions` itself, so a `/v1` here gives HTTP 404.
    /// Returns `nil` when the value has no scheme or host (e.g. `localhost:11434`).
    static func baseURL(_ host: String) -> URL? {
        var base = host.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.lowercased().hasSuffix("/v1") { base.removeLast(3) }
        guard let url = URL(string: base), url.scheme != nil, url.host != nil else { return nil }
        return url
    }
}
