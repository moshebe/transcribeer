import Foundation
import TOMLDecoder

public struct AppConfig: Equatable, Sendable {
    public var language: String = "auto"
    public var whisperModel: String = "openai_whisper-large-v3-turbo"
    public var diarization: String = "pyannote"
    public var numSpeakers: Int = 0
    public var llmBackend: String = "ollama"
    public var llmModel: String = "llama3"
    public var ollamaHost: String = "http://localhost:11434"
    public var sessionsDir: String = "~/.transcribeer/sessions"
    public var captureBin: String = AppConfig.defaultCaptureBin()
    public var pipelineMode: String = "record+transcribe+summarize"
    public var zoomAutoRecord: Bool = false
    public var promptOnStop: Bool = true

    public init() {}

    public var expandedSessionsDir: String {
        (sessionsDir as NSString).expandingTildeInPath
    }

    public var expandedCaptureBin: String {
        (captureBin as NSString).expandingTildeInPath
    }

    public static func defaultCaptureBin() -> String {
        let brewPath = "/opt/homebrew/opt/transcribeer/libexec/bin/capture-bin"
        if FileManager.default.fileExists(atPath: brewPath) {
            return brewPath
        }
        return "~/.transcribeer/bin/capture-bin"
    }

    public static let modelsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/models", isDirectory: true)
    }()
}

// MARK: - TOML file structures for decoding

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

// MARK: - Load / Save

public enum ConfigManager {
    public static let configPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/config.toml")
    }()

    public static func load() -> AppConfig {
        var cfg = AppConfig()
        guard let data = try? Data(contentsOf: configPath) else { return cfg }
        guard let toml = try? TOMLDecoder().decode(TOMLFile.self, from: data) else { return cfg }

        if let p = toml.pipeline {
            if let v = p.mode { cfg.pipelineMode = v }
            if let v = p.zoom_auto_record { cfg.zoomAutoRecord = v }
        }
        if let t = toml.transcription {
            if let v = t.language { cfg.language = v }
            if let v = t.model { cfg.whisperModel = v }
            if let v = t.diarization { cfg.diarization = v }
            if let v = t.num_speakers { cfg.numSpeakers = v }
        }
        if let s = toml.summarization {
            if let v = s.backend { cfg.llmBackend = v }
            if let v = s.model { cfg.llmModel = v }
            if let v = s.ollama_host { cfg.ollamaHost = v }
            if let v = s.prompt_on_stop { cfg.promptOnStop = v }
        }
        if let p = toml.paths {
            if let v = p.sessions_dir { cfg.sessionsDir = v }
            if let v = p.capture_bin { cfg.captureBin = v }
        }
        return cfg
    }

    public static func save(_ cfg: AppConfig) {
        let dir = configPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let lines = """
        [pipeline]
        mode = "\(cfg.pipelineMode)"
        zoom_auto_record = \(cfg.zoomAutoRecord)

        [transcription]
        language = "\(cfg.language)"
        model = "\(cfg.whisperModel)"
        diarization = "\(cfg.diarization)"
        num_speakers = \(cfg.numSpeakers)

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
