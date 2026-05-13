import Foundation
import Testing
@testable import TranscribeerApp

struct TranscriptionBackendAvailabilityTests {
    @Test("WhisperKit is always available")
    func whisperKitAlwaysAvailable() {
        let availability = TranscriptionBackendAvailability(available: [])

        #expect(availability.isAvailable(.whisperkit))
        #expect(availability.isAvailable(.openai) == false)
        #expect(availability.isAvailable(.gemini) == false)
    }

    @Test("Keychain credentials enable matching cloud backends")
    func keychainCredentialsEnableCloudBackends() {
        let availability = TranscriptionBackendAvailability.resolve(environment: [:]) { key in
            key == TranscriptionBackend.openai.keychainKey ? "sk-test" : nil
        }

        #expect(availability.isAvailable(.whisperkit))
        #expect(availability.isAvailable(.openai))
        #expect(availability.isAvailable(.gemini) == false)
    }

    @Test("Environment variables enable cloud backends without Keychain entries")
    func environmentCredentialsEnableCloudBackends() {
        let availability = TranscriptionBackendAvailability.resolve(
            environment: [
                "OPENAI_API_KEY": "sk-env",
                "GEMINI_API_KEY": "gemini-env",
            ]
        ) { _ in nil }

        #expect(availability.isAvailable(.openai))
        #expect(availability.isAvailable(.gemini))
    }

    @Test("Google API key is accepted for Gemini")
    func googleAPIKeyEnablesGemini() {
        let availability = TranscriptionBackendAvailability.resolve(
            environment: ["GOOGLE_API_KEY": "google-env"]
        ) { _ in nil }

        #expect(availability.isAvailable(.openai) == false)
        #expect(availability.isAvailable(.gemini))
    }
}
