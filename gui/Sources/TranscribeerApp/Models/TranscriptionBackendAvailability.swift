import Foundation

/// Cached availability for the transcription backend picker.
///
/// Keychain checks shell out through `/usr/bin/security`, so views must not run
/// them while SwiftUI is computing `body`. Resolve this value asynchronously and
/// keep menu rendering pure.
struct TranscriptionBackendAvailability: Equatable, Sendable {
    static let localOnly = Self(available: [.whisperkit])

    private let available: Set<TranscriptionBackend>

    init(available: Set<TranscriptionBackend>) {
        self.available = available.union([.whisperkit])
    }

    func isAvailable(_ backend: TranscriptionBackend) -> Bool {
        available.contains(backend)
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        apiKeyProvider: (String) -> String? = KeychainHelper.getAPIKey
    ) -> Self {
        var available: Set<TranscriptionBackend> = [.whisperkit]
        for backend in TranscriptionBackend.allCases where backend.usesAPIKey {
            if hasCredential(for: backend, environment: environment, apiKeyProvider: apiKeyProvider) {
                available.insert(backend)
            }
        }
        return Self(available: available)
    }

    private static func hasCredential(
        for backend: TranscriptionBackend,
        environment: [String: String],
        apiKeyProvider: (String) -> String?
    ) -> Bool {
        if let key = apiKeyProvider(backend.keychainKey), !key.isEmpty {
            return true
        }
        if let name = backend.envVar,
           let value = environment[name],
           !value.isEmpty {
            return true
        }
        // Gemini accepts the generic Google AI key name as a secondary
        // fallback — same behaviour as `CloudTranscriptionService`.
        if backend == .gemini,
           let value = environment["GOOGLE_API_KEY"],
           !value.isEmpty {
            return true
        }
        return false
    }
}
