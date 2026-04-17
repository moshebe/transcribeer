import Foundation
import TOMLDecoder

/// Mirrors ~/.transcribeer/config.toml.
struct AppConfig: Equatable {
    var language: String = "auto"
    var whisperModel: String = "openai_whisper-large-v3_turbo"
    var diarization: String = "pyannote"
    var numSpeakers: Int = 0
    var llmBackend: String = "ollama"
    var llmModel: String = "llama3"
    var ollamaHost: String = "http://localhost:11434"
    var sessionsDir: String = "~/.transcribeer/sessions"
    var captureBin: String = Self.defaultCaptureBin()
    var pipelineMode: String = "record+transcribe+summarize"
    var zoomAutoRecord: Bool = false
    var promptOnStop: Bool = true

    var expandedSessionsDir: String {
        (sessionsDir as NSString).expandingTildeInPath
    }

    var expandedCaptureBin: String {
        (captureBin as NSString).expandingTildeInPath
    }

    static func defaultCaptureBin() -> String {
        let brewPath = "/opt/homebrew/opt/transcribeer/libexec/bin/capture-bin"
        if FileManager.default.fileExists(atPath: brewPath) {
            return brewPath
        }
        return "~/.transcribeer/bin/capture-bin"
    }
}

// MARK: - TOML file structures for decoding
//
// Optional booleans here intentionally distinguish "absent" from "present and
// false" during TOML decoding so we can fall back to the AppConfig default.
// swiftlint:disable discouraged_optional_boolean

private struct TOMLFile: Decodable {
    var pipeline: PipelineSection?
    var transcription: TranscriptionSection?
    var summarization: SummarizationSection?
    var paths: PathsSection?
}

private struct PipelineSection: Decodable {
    var mode: String?
    var zoom_auto_record: Bool?
}

private struct TranscriptionSection: Decodable {
    var language: String?
    var model: String?
    var diarization: String?
    var num_speakers: Int?
}

private struct SummarizationSection: Decodable {
    var backend: String?
    var model: String?
    var ollama_host: String?
    var prompt_on_stop: Bool?
}

private struct PathsSection: Decodable {
    var sessions_dir: String?
    var capture_bin: String?
}

// swiftlint:enable discouraged_optional_boolean

// MARK: - Load / Save

extension AppConfig {
    /// Migrate legacy short model names (e.g. `"large-v3-turbo"`) to the
    /// canonical WhisperKit identifiers that match the HuggingFace repo folders.
    /// WhisperKit resolves models via glob on the folder name, so the hyphenated
    /// legacy names match nothing and throw `modelsUnavailable`.
    static func canonicalWhisperModel(_ name: String) -> String {
        switch name {
        case "tiny": "openai_whisper-tiny"
        case "base": "openai_whisper-base"
        case "small": "openai_whisper-small"
        case "medium": "openai_whisper-medium"
        case "large-v2": "openai_whisper-large-v2"
        case "large-v3": "openai_whisper-large-v3"
        case "large-v3-turbo", "large-v3_turbo": "openai_whisper-large-v3_turbo"
        default: name
        }
    }
}

enum ConfigManager {
    static let configPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/config.toml")
    }()

    static func load() -> AppConfig {
        var cfg = AppConfig()
        guard
            let data = try? Data(contentsOf: configPath),
            let toml = try? TOMLDecoder().decode(TOMLFile.self, from: data)
        else { return cfg }

        if let pipeline = toml.pipeline {
            cfg.pipelineMode = pipeline.mode ?? cfg.pipelineMode
            cfg.zoomAutoRecord = pipeline.zoom_auto_record ?? cfg.zoomAutoRecord
        }
        if let transcription = toml.transcription {
            cfg.language = transcription.language ?? cfg.language
            cfg.whisperModel = transcription.model.map(AppConfig.canonicalWhisperModel) ?? cfg.whisperModel
            cfg.diarization = transcription.diarization ?? cfg.diarization
            cfg.numSpeakers = transcription.num_speakers ?? cfg.numSpeakers
        }
        if let summarization = toml.summarization {
            cfg.llmBackend = summarization.backend ?? cfg.llmBackend
            cfg.llmModel = summarization.model ?? cfg.llmModel
            cfg.ollamaHost = summarization.ollama_host ?? cfg.ollamaHost
            cfg.promptOnStop = summarization.prompt_on_stop ?? cfg.promptOnStop
        }
        if let paths = toml.paths {
            cfg.sessionsDir = paths.sessions_dir ?? cfg.sessionsDir
            cfg.captureBin = paths.capture_bin ?? cfg.captureBin
        }
        return cfg
    }

    static func save(_ cfg: AppConfig) {
        let dir = configPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let speakers = cfg.numSpeakers
        let lines = """
        [pipeline]
        mode = "\(cfg.pipelineMode)"
        zoom_auto_record = \(cfg.zoomAutoRecord)

        [transcription]
        language = "\(cfg.language)"
        model = "\(cfg.whisperModel)"
        diarization = "\(cfg.diarization)"
        num_speakers = \(speakers)

        [summarization]
        backend = "\(cfg.llmBackend)"
        model = "\(cfg.llmModel)"
        ollama_host = "\(cfg.ollamaHost)"
        prompt_on_stop = \(cfg.promptOnStop)

        [paths]
        sessions_dir = "\(cfg.sessionsDir)"
        capture_bin = "\(cfg.captureBin)"
        """
        try? lines.write(to: configPath, atomically: true, encoding: .utf8)
    }
}
