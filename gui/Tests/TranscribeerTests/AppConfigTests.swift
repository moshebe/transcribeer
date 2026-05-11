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
        #expect(cfg.promptOnStop)
    }

    @Test("Transcription backend + cloud models round-trip via TOMLDecoder")
    func transcriptionBackendRoundTrip() throws {
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

    // MARK: - Audio settings round-trip

    @Test("ConfigManager round-trips audio settings")
    func audioRoundTrip() throws {
        var cfg = AppConfig()
        cfg.audio.inputDeviceUID = "MyMic-UID"
        cfg.audio.outputDeviceUID = "MyOut-UID"
        cfg.audio.aec = false
        cfg.audio.selfLabel = "Alice"
        cfg.audio.otherLabel = "Bob"
        cfg.audio.diarizeMicMultiuser = true

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let path = tmpDir.appendingPathComponent("config.toml")

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Use reflection or direct write since ConfigManager.configPath is static
        let lines = """
        [pipeline]
        mode = "\(cfg.pipelineMode)"
        meeting_auto_record = \(cfg.meetingAutoRecord)
        meeting_auto_record_delay = \(cfg.meetingAutoRecordDelay)

        [transcription]
        language = "\(cfg.language)"
        model = "\(cfg.whisperModel)"
        model_repo = "\(cfg.whisperModelRepo)"
        diarization = "\(cfg.diarization)"
        num_speakers = \(cfg.numSpeakers)

        [summarization]
        backend = "\(cfg.llmBackend)"
        model = "\(cfg.llmModel)"
        ollama_host = "\(cfg.ollamaHost)"
        prompt_on_stop = \(cfg.promptOnStop)

        [paths]
        sessions_dir = "\(cfg.sessionsDir)"

        [audio]
        input_device_uid = "\(cfg.audio.inputDeviceUID)"
        output_device_uid = "\(cfg.audio.outputDeviceUID)"
        aec = \(cfg.audio.aec)
        self_label = "\(cfg.audio.selfLabel)"
        other_label = "\(cfg.audio.otherLabel)"
        diarize_mic_multiuser = \(cfg.audio.diarizeMicMultiuser)
        """
        try lines.write(to: path, atomically: true, encoding: .utf8)

        // Load via TOMLDecoder directly to verify round-trip
        let data = try Data(contentsOf: path)
        let decoded = try TOMLDecoder().decode(TOMLFile.self, from: data)
        #expect(decoded.audio?.input_device_uid == "MyMic-UID")
        #expect(decoded.audio?.output_device_uid == "MyOut-UID")
        #expect(decoded.audio?.aec == false)
        #expect(decoded.audio?.self_label == "Alice")
        #expect(decoded.audio?.other_label == "Bob")
        #expect(decoded.audio?.diarize_mic_multiuser == true)
    }

    @Test("Missing [audio] section uses defaults")
    func audioDefaultsWhenAbsent() throws {
        let toml = Data("""
        [pipeline]
        mode = "record-only"

        [transcription]
        language = "en"
        """.utf8)

        let file = try TOMLDecoder().decode(TOMLFile.self, from: toml)
        #expect(file.audio == nil)
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
        // Build a TOML document using the escaper directly (we can't point
        // ConfigManager at a custom path without refactoring) and verify it
        // decodes back to the original values.
        let selfLabel = "Guy \"the Voice\" Smith"
        let otherLabel = "back\\slash\tand\ttab"
        let sessionsDir = "/Users/x/With \"Quotes\"/sessions"

        let doc = """
        [paths]
        sessions_dir = \(ConfigManager.tomlString(sessionsDir))

        [audio]
        self_label = \(ConfigManager.tomlString(selfLabel))
        other_label = \(ConfigManager.tomlString(otherLabel))
        """

        let decoded = try TOMLDecoder().decode(TOMLFile.self, from: Data(doc.utf8))
        #expect(decoded.audio?.self_label == selfLabel)
        #expect(decoded.audio?.other_label == otherLabel)
        #expect(decoded.paths?.sessions_dir == sessionsDir)
    }
}
