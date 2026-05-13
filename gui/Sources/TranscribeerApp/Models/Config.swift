import Foundation
import TOMLDecoder

/// Mirrors ~/.transcribeer/config.toml.
struct AppConfig: Equatable {
    var language: String = "auto"
    /// Selected transcription backend (`whisperkit`, `openai`, `gemini`).
    /// Mirrors `TranscriptionBackend`; stored as the raw string so config.toml
    /// stays human-readable.
    var transcriptionBackend: String = "whisperkit"
    var whisperModel: String = "openai_whisper-large-v3_turbo"
    var whisperModelRepo: String = ""
    /// Cloud model used when `transcriptionBackend == "openai"`. `whisper-1`
    /// is the only OpenAI audio model that returns segment-level timestamps.
    var openaiTranscriptionModel: String = "whisper-1"
    /// Cloud model used when `transcriptionBackend == "gemini"`. Must accept
    /// audio inputs and support structured JSON output (Gemini 2.5+).
    var geminiTranscriptionModel: String = "gemini-2.5-flash"
    var diarization: String = "pyannote"
    var numSpeakers: Int = 0
    var llmBackend: String = "ollama"
    var llmModel: String = "llama3"
    var ollamaHost: String = "http://localhost:11434"
    var sessionsDir: String = "~/.transcribeer/sessions"
    var pipelineMode: String = "record+transcribe+summarize"
    var meetingAutoRecord: Bool = false
    var meetingAutoRecordDelay: Int = 5
    /// Bundle IDs of apps that trigger auto-record when a meeting is detected.
    /// Apps outside this set still fire a notification but do not auto-start.
    /// Default: Zoom only — prevents Slack huddles, browser-based meetings, etc.
    /// from auto-recording unless the user opts in.
    var meetingAutoRecordApps: Set<String> = ["us.zoom.xos"]
    /// Read meeting topic and participant list from the Zoom app via
    /// Accessibility while a recording is in progress. Covers both enrichments
    /// as a single on/off switch — disabling skips the AX walks entirely.
    var zoomEnricherEnabled: Bool = true
    /// Upper bound on how many participants we will observe and persist for a
    /// meeting. Large meetings (classrooms, town halls, webinars) would fill
    /// `meta.json` with churn that isn't useful for per-speaker transcription,
    /// so we skip collection entirely while the observed count exceeds this.
    /// Values `<= 0` disable participant capture.
    var maxMeetingParticipants: Int = 10
    var promptOnStop: Bool = true
    /// When true, a daily background job processes the previous day's
    /// recordings (transcribe + summarize) at `scheduledTranscriptionHour`.
    var scheduledTranscriptionEnabled: Bool = false
    /// Hour-of-day (0–23, local time) the scheduled job fires. Default 3 AM.
    var scheduledTranscriptionHour: Int = 3
    var audio = AudioSettings()

    var expandedSessionsDir: String {
        (sessionsDir as NSString).expandingTildeInPath
    }

    struct AudioSettings: Equatable {
        var inputDeviceUID: String = ""
        var outputDeviceUID: String = ""
        var aec: Bool = false
        var selfLabel: String = "You"
        var otherLabel: String = "Them"
        var diarizeMicMultiuser: Bool = false
    }
}

// MARK: - TOML file structures for decoding
//
// Optional booleans here intentionally distinguish "absent" from "present and
// false" during TOML decoding so we can fall back to the AppConfig default.
// swiftlint:disable discouraged_optional_boolean

struct TOMLFile: Decodable {
    var pipeline: PipelineSection?
    var transcription: TranscriptionSection?
    var summarization: SummarizationSection?
    var paths: PathsSection?
    var audio: AudioSection?
}

struct PipelineSection: Decodable {
    var mode: String?
    var meeting_auto_record: Bool?
    var meeting_auto_record_delay: Int?
    var meeting_auto_record_apps: [String]?
    var zoom_enricher_enabled: Bool?
    var max_meeting_participants: Int?
    var scheduled_transcription_enabled: Bool?
    var scheduled_transcription_hour: Int?
}

struct TranscriptionSection: Decodable {
    var language: String?
    var backend: String?
    var model: String?
    var model_repo: String?
    var openai_model: String?
    var gemini_model: String?
    var diarization: String?
    var num_speakers: Int?
}

struct SummarizationSection: Decodable {
    var backend: String?
    var model: String?
    var ollama_host: String?
    var prompt_on_stop: Bool?
}

struct PathsSection: Decodable {
    var sessions_dir: String?
}

struct AudioSection: Decodable {
    var input_device_uid: String?
    var output_device_uid: String?
    var aec: Bool?
    var self_label: String?
    var other_label: String?
    var diarize_mic_multiuser: Bool?
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

        if let pipeline = toml.pipeline { applyPipeline(pipeline, to: &cfg) }
        if let transcription = toml.transcription { applyTranscription(transcription, to: &cfg) }
        if let summarization = toml.summarization { applySummarization(summarization, to: &cfg) }
        if let paths = toml.paths { applyPaths(paths, to: &cfg) }
        if let audio = toml.audio { applyAudio(audio, to: &cfg) }
        return cfg
    }

    private static func applyPipeline(_ s: PipelineSection, to cfg: inout AppConfig) {
        cfg.pipelineMode = s.mode ?? cfg.pipelineMode
        cfg.meetingAutoRecord = s.meeting_auto_record ?? cfg.meetingAutoRecord
        if let delay = s.meeting_auto_record_delay, delay >= 0 {
            cfg.meetingAutoRecordDelay = delay
        }
        if let apps = s.meeting_auto_record_apps {
            cfg.meetingAutoRecordApps = Set(apps)
        }
        if let maxParticipants = s.max_meeting_participants {
            cfg.maxMeetingParticipants = maxParticipants
        }
        cfg.zoomEnricherEnabled = s.zoom_enricher_enabled ?? cfg.zoomEnricherEnabled
        cfg.scheduledTranscriptionEnabled =
            s.scheduled_transcription_enabled ?? cfg.scheduledTranscriptionEnabled
        if let hour = s.scheduled_transcription_hour, (0...23).contains(hour) {
            cfg.scheduledTranscriptionHour = hour
        }
    }

    private static func applyTranscription(_ s: TranscriptionSection, to cfg: inout AppConfig) {
        cfg.language = s.language ?? cfg.language
        cfg.transcriptionBackend = s.backend ?? cfg.transcriptionBackend
        cfg.whisperModel = s.model.map(AppConfig.canonicalWhisperModel) ?? cfg.whisperModel
        cfg.whisperModelRepo = s.model_repo ?? cfg.whisperModelRepo
        cfg.openaiTranscriptionModel = s.openai_model ?? cfg.openaiTranscriptionModel
        cfg.geminiTranscriptionModel = s.gemini_model ?? cfg.geminiTranscriptionModel
        cfg.diarization = s.diarization ?? cfg.diarization
        cfg.numSpeakers = s.num_speakers ?? cfg.numSpeakers
    }

    private static func applySummarization(_ s: SummarizationSection, to cfg: inout AppConfig) {
        cfg.llmBackend = s.backend ?? cfg.llmBackend
        cfg.llmModel = s.model ?? cfg.llmModel
        cfg.ollamaHost = s.ollama_host ?? cfg.ollamaHost
        cfg.promptOnStop = s.prompt_on_stop ?? cfg.promptOnStop
    }

    private static func applyPaths(_ s: PathsSection, to cfg: inout AppConfig) {
        cfg.sessionsDir = s.sessions_dir ?? cfg.sessionsDir
    }

    private static func applyAudio(_ s: AudioSection, to cfg: inout AppConfig) {
        cfg.audio.inputDeviceUID = s.input_device_uid ?? cfg.audio.inputDeviceUID
        cfg.audio.outputDeviceUID = s.output_device_uid ?? cfg.audio.outputDeviceUID
        cfg.audio.aec = s.aec ?? cfg.audio.aec
        cfg.audio.selfLabel = s.self_label ?? cfg.audio.selfLabel
        cfg.audio.otherLabel = s.other_label ?? cfg.audio.otherLabel
        cfg.audio.diarizeMicMultiuser = s.diarize_mic_multiuser ?? cfg.audio.diarizeMicMultiuser
    }

    static func save(_ cfg: AppConfig) {
        let dir = configPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let speakers = cfg.numSpeakers
        let autoRecordApps = cfg.meetingAutoRecordApps
            .sorted()
            .map(tomlString)
            .joined(separator: ", ")
        let lines = """
        [pipeline]
        mode = \(tomlString(cfg.pipelineMode))
        meeting_auto_record = \(cfg.meetingAutoRecord)
        meeting_auto_record_delay = \(cfg.meetingAutoRecordDelay)
        meeting_auto_record_apps = [\(autoRecordApps)]
        max_meeting_participants = \(cfg.maxMeetingParticipants)
        zoom_enricher_enabled = \(cfg.zoomEnricherEnabled)
        scheduled_transcription_enabled = \(cfg.scheduledTranscriptionEnabled)
        scheduled_transcription_hour = \(cfg.scheduledTranscriptionHour)

        [transcription]
        language = \(tomlString(cfg.language))
        backend = \(tomlString(cfg.transcriptionBackend))
        model = \(tomlString(cfg.whisperModel))
        model_repo = \(tomlString(cfg.whisperModelRepo))
        openai_model = \(tomlString(cfg.openaiTranscriptionModel))
        gemini_model = \(tomlString(cfg.geminiTranscriptionModel))
        diarization = \(tomlString(cfg.diarization))
        num_speakers = \(speakers)

        [summarization]
        backend = \(tomlString(cfg.llmBackend))
        model = \(tomlString(cfg.llmModel))
        ollama_host = \(tomlString(cfg.ollamaHost))
        prompt_on_stop = \(cfg.promptOnStop)

        [paths]
        sessions_dir = \(tomlString(cfg.sessionsDir))

        [audio]
        input_device_uid = \(tomlString(cfg.audio.inputDeviceUID))
        output_device_uid = \(tomlString(cfg.audio.outputDeviceUID))
        aec = \(cfg.audio.aec)
        self_label = \(tomlString(cfg.audio.selfLabel))
        other_label = \(tomlString(cfg.audio.otherLabel))
        diarize_mic_multiuser = \(cfg.audio.diarizeMicMultiuser)
        """
        try? lines.write(to: configPath, atomically: true, encoding: .utf8)
    }

    /// Encode a string as a TOML basic string literal — wraps in quotes and
    /// escapes the characters TOML requires (`\`, `"`, and common control
    /// characters).  Without this, a user label containing a quote or a
    /// backslash would corrupt the file and prevent the next load.
    static func tomlString(_ s: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(s.count + 2)
        for ch in s {
            switch ch {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\u{08}": escaped += "\\b"
            case "\u{0C}": escaped += "\\f"
            default:
                // TOML basic strings forbid control chars (0x00–0x1F, 0x7F)
                // other than tab; encode via \uXXXX.
                let scalar = ch.unicodeScalars.first.map(\.value) ?? 0
                if scalar < 0x20 || scalar == 0x7F {
                    escaped += String(format: "\\u%04X", scalar)
                } else {
                    escaped.append(ch)
                }
            }
        }
        return "\"\(escaped)\""
    }
}
