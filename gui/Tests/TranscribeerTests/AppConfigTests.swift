import Foundation
import TOMLDecoder
import Testing
@testable import TranscribeerApp

struct AppConfigTests {
    @Test("Default config has expected values")
    func defaults() {
        let cfg = AppConfig()
        #expect(cfg.language == "auto")
        #expect(cfg.whisperModel == "openai_whisper-large-v3_turbo")
        #expect(cfg.transcriptionBackend == "whisperkit")
        #expect(cfg.openaiTranscriptionModel == "whisper-1")
        #expect(cfg.geminiTranscriptionModel == "gemini-2.5-flash")
        #expect(cfg.diarization == "pyannote")
        #expect(cfg.numSpeakers == 0)
        #expect(cfg.llmBackend == "ollama")
        #expect(cfg.llmModel == "llama3")
        #expect(cfg.ollamaHost == "http://localhost:11434")
        #expect(cfg.sessionsDir == "~/.transcribeer/sessions")
        #expect(cfg.pipelineMode == "record+transcribe+summarize")
        #expect(!cfg.meetingAutoRecord)
        #expect(!cfg.promptOnStop) // default false — user opts in (Track 4.3)
    }

    @Test("TOML decoding reads transcription backend and cloud model fields")
    func decodesTranscriptionBackend() throws {
        let doc = """
        [transcription]
        language = "en"
        backend = "openai"
        model = "openai_whisper-large-v3_turbo"
        openai_model = "gpt-4o-transcribe"
        gemini_model = "gemini-2.5-pro"
        diarization = "none"
        num_speakers = 0
        """
        let decoded = try TOMLDecoder().decode(TOMLFile.self, from: Data(doc.utf8))
        #expect(decoded.transcription?.backend == "openai")
        #expect(decoded.transcription?.openai_model == "gpt-4o-transcribe")
        #expect(decoded.transcription?.gemini_model == "gemini-2.5-pro")
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

    @Test("canonicalWhisperModel migrates legacy short names")
    func canonicalWhisperModel() {
        #expect(AppConfig.canonicalWhisperModel("large-v3-turbo") == "openai_whisper-large-v3_turbo")
        #expect(AppConfig.canonicalWhisperModel("openai_whisper-large-v3-turbo") == "openai_whisper-large-v3_turbo")
        #expect(AppConfig.canonicalWhisperModel("large-v3") == "openai_whisper-large-v3")
        #expect(AppConfig.canonicalWhisperModel("base") == "openai_whisper-base")
        // Already-canonical names pass through unchanged.
        #expect(AppConfig.canonicalWhisperModel("openai_whisper-large-v3_turbo") == "openai_whisper-large-v3_turbo")
        // Unknown names pass through so custom repos keep working.
        #expect(AppConfig.canonicalWhisperModel("distil-whisper_distil-large-v3") == "distil-whisper_distil-large-v3")
    }

    @Test("Changing the language changes config equality")
    func equatable() {
        let a = AppConfig()
        var b = AppConfig()
        #expect(a == b)

        b.language = "en"
        #expect(a != b)
    }

    // MARK: - Audio settings round-trip

    @Test("ConfigManager round-trips audio settings")
    func audioRoundTrip() throws {
        var cfg = AppConfig()
        cfg.audio.inputDeviceUID = "MyMic-UID"
        cfg.audio.outputDeviceUID = "MyOut-UID"
        cfg.audio.aec = true
        cfg.audio.selfLabel = "Alice \"Host\""
        cfg.audio.otherLabel = "Bob"
        cfg.audio.ffmpegPath = "/opt/homebrew/bin/ffmpeg"
        cfg.audio.diarizeMicMultiuser = true

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let path = tmpDir.appendingPathComponent("config.toml")

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        ConfigManager.save(cfg, to: path)
        let decoded = ConfigManager.load(from: path)
        #expect(decoded.audio.inputDeviceUID == "MyMic-UID")
        #expect(decoded.audio.outputDeviceUID == "MyOut-UID")
        #expect(decoded.audio.aec)
        #expect(decoded.audio.selfLabel == "Alice \"Host\"")
        #expect(decoded.audio.otherLabel == "Bob")
        #expect(decoded.audio.ffmpegPath == "/opt/homebrew/bin/ffmpeg")
        #expect(decoded.audio.diarizeMicMultiuser == true)
    }

    @Test("Missing [audio] section uses defaults")
    func audioDefaultsWhenAbsent() throws {
        let toml = Data("""
        [pipeline]
        mode = "record-only"

        [transcription]
        language = "en"
        """.utf8)

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("config-\(UUID()).toml")
        defer { try? FileManager.default.removeItem(at: path) }
        try toml.write(to: path)

        let config = ConfigManager.load(from: path)
        #expect(config.language == "en")
        #expect(config.audio.inputDeviceUID.isEmpty)
        #expect(config.audio.outputDeviceUID.isEmpty)
        #expect(config.audio.aec == false)
        #expect(config.audio.selfLabel == "You")
        #expect(config.audio.otherLabel == "Them")
    }

    // MARK: - TOML string escaping

    @Test(
        "tomlString escapes values that would otherwise corrupt the file",
        arguments: [
            (input: "simple", expected: "\"simple\""),
            (input: "has \"quote\"", expected: "\"has \\\"quote\\\"\""),
            (input: "back\\slash", expected: "\"back\\\\slash\""),
            (input: "line1\nline2", expected: "\"line1\\nline2\""),
            (input: "tab\there", expected: "\"tab\\there\""),
            (input: "\u{01}control", expected: "\"\\u0001control\""),
            (input: "", expected: "\"\""),
        ]
    )
    func tomlStringEscape(input: String, expected: String) {
        #expect(ConfigManager.tomlString(input) == expected)
    }

    @Test("ConfigManager round-trips strings containing quotes and backslashes")
    func tomlStringRoundTrip() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("config-\(UUID()).toml")
        defer { try? FileManager.default.removeItem(at: path) }
        var config = AppConfig()
        config.audio.selfLabel = "Guy \"the Voice\" Smith"
        config.audio.otherLabel = "back\\slash\tand\ttab"
        config.sessionsDir = "/Users/x/With \"Quotes\"/sessions"

        ConfigManager.save(config, to: path)
        let decoded = ConfigManager.load(from: path)

        #expect(decoded.audio.selfLabel == config.audio.selfLabel)
        #expect(decoded.audio.otherLabel == config.audio.otherLabel)
        #expect(decoded.sessionsDir == config.sessionsDir)
    }
}
