import Foundation
import Testing
@testable import TranscribeerApp

struct AppConfigTests {
    @Test("Default config has expected values")
    func defaults() {
        let cfg = AppConfig()
        #expect(cfg.language == "auto")
        #expect(cfg.whisperModel == "openai_whisper-large-v3_turbo")
        #expect(cfg.diarization == "pyannote")
        #expect(cfg.numSpeakers == 0)
        #expect(cfg.llmBackend == "ollama")
        #expect(cfg.llmModel == "llama3")
        #expect(cfg.ollamaHost == "http://localhost:11434")
        #expect(cfg.sessionsDir == "~/.transcribeer/sessions")
        #expect(cfg.pipelineMode == "record+transcribe+summarize")
        #expect(!cfg.zoomAutoRecord)
        #expect(cfg.promptOnStop)
    }

    @Test("expandedSessionsDir resolves tilde to home directory")
    func expandedSessionsDir() {
        var cfg = AppConfig()
        cfg.sessionsDir = "~/custom/sessions"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(cfg.expandedSessionsDir == "\(home)/custom/sessions")
    }

    @Test("expandedSessionsDir passes through absolute paths unchanged")
    func absoluteSessionsDir() {
        var cfg = AppConfig()
        cfg.sessionsDir = "/tmp/sessions"
        #expect(cfg.expandedSessionsDir == "/tmp/sessions")
    }

    @Test("expandedCaptureBin resolves tilde")
    func expandedCaptureBin() {
        var cfg = AppConfig()
        cfg.captureBin = "~/.transcribeer/bin/capture-bin"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(cfg.expandedCaptureBin == "\(home)/.transcribeer/bin/capture-bin")
    }

    @Test("canonicalWhisperModel migrates legacy short names")
    func canonicalWhisperModel() {
        #expect(AppConfig.canonicalWhisperModel("large-v3-turbo") == "openai_whisper-large-v3_turbo")
        #expect(AppConfig.canonicalWhisperModel("large-v3") == "openai_whisper-large-v3")
        #expect(AppConfig.canonicalWhisperModel("base") == "openai_whisper-base")
        // Already-canonical names pass through unchanged.
        #expect(AppConfig.canonicalWhisperModel("openai_whisper-large-v3_turbo") == "openai_whisper-large-v3_turbo")
        // Unknown names pass through so custom repos keep working.
        #expect(AppConfig.canonicalWhisperModel("distil-whisper_distil-large-v3") == "distil-whisper_distil-large-v3")
    }

    @Test("Equatable conformance compares all fields")
    func equatable() {
        let a = AppConfig()
        var b = AppConfig()
        #expect(a == b)

        b.language = "en"
        #expect(a != b)
    }
}
