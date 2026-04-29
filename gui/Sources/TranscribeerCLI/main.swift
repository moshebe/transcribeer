import ArgumentParser
import Foundation
import TranscribeerCore

@main
struct Transcribeer: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "transcribeer",
        abstract: "Local-first audio capture, transcription, and summarization.",
        subcommands: [Record.self, Transcribe.self, Summarize.self, Run.self]
    )
}

// MARK: - record

struct Record: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Capture system audio to a WAV file."
    )

    @Option(name: .shortAndLong, help: "Stop after N seconds. Omit for manual stop (Ctrl+C).")
    var duration: Int?

    @Option(name: .shortAndLong, help: "Output WAV path. Defaults to a new session directory.")
    var out: String?

    @Option(name: .long, help: "Write PID here so an external process can stop recording.")
    var pidFile: String?

    func run() async throws {
        let cfg = ConfigManager.load()
        let outPath: String
        if let out {
            outPath = (out as NSString).expandingTildeInPath
        } else {
            let sess = SessionManager.newSession(sessionsDir: cfg.expandedSessionsDir)
            outPath = sess.appendingPathComponent("audio.m4a").path
        }

        print("Recording → \(outPath)")
        if let d = duration {
            print("  Auto-stop after \(d)s. Press Ctrl+C to stop early.")
        } else {
            print("  Press Ctrl+C to stop.")
        }

        try runCapture(captureBin: cfg.expandedCaptureBin, audioPath: outPath, duration: duration, pidFile: pidFile)
        print("Saved: \(outPath)")
    }
}

// MARK: - transcribe

struct Transcribe: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Transcribe an audio file with speaker diarization."
    )

    @Argument(help: "WAV (or any audio) file to transcribe.")
    var audio: String

    @Option(name: .long, help: "Language code: he, en, auto. Overrides config.")
    var lang: String?

    @Flag(name: .long, help: "Skip speaker diarization.")
    var noDiarize = false

    @Option(
        name: .long,
        help: "Number of distinct speakers. Overrides config; 0 = auto-detect."
    )
    var numSpeakers: Int?

    @Option(name: .shortAndLong, help: "Output .txt path.")
    var out: String?

    func validate() throws {
        if let ns = numSpeakers, ns < 0 {
            throw ValidationError("--num-speakers must be >= 0 (0 means auto-detect).")
        }
    }

    func run() async throws {
        let cfg = ConfigManager.load()
        let audioURL = URL(fileURLWithPath: (audio as NSString).expandingTildeInPath)
        let outPath = out.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? audioURL.deletingPathExtension().appendingPathExtension("diarized.txt")

        let language = lang ?? cfg.language
        print("Transcribing: \(audioURL.path)")
        print("  Language: \(language)  |  Diarization: \(noDiarize ? "none" : cfg.diarization)")

        let text = try await transcribeAndFormat(
            audioURL: audioURL,
            language: language,
            diarization: noDiarize ? "none" : cfg.diarization,
            numSpeakers: resolveNumSpeakers(override: numSpeakers, config: cfg.numSpeakers),
            cfg: cfg
        )

        try text.write(to: outPath, atomically: true, encoding: .utf8)
        print("Transcript: \(outPath.path)")
    }
}

// MARK: - summarize

struct Summarize: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Summarize a transcript using an LLM."
    )

    @Argument(help: "Transcript .txt file.")
    var transcript: String

    @Option(name: .shortAndLong, help: "Output .md path.")
    var out: String?

    @Option(name: .long, help: "LLM backend: openai, anthropic, ollama.")
    var backend: String?

    @Option(name: .long, help: "Named prompt profile from ~/.transcribeer/prompts/.")
    var profile: String?

    func run() async throws {
        let cfg = ConfigManager.load()
        let txURL = URL(fileURLWithPath: (transcript as NSString).expandingTildeInPath)
        let outURL = out.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? txURL.deletingPathExtension().appendingPathExtension("summary.md")

        let llmBackend = backend ?? cfg.llmBackend
        let text = try String(contentsOf: txURL, encoding: .utf8)
        let prompt = SummarizationService.loadPromptProfile(profile)

        print("Summarizing: \(txURL.path)")
        print("  Backend: \(llmBackend) / \(cfg.llmModel)")

        let summary = try await SummarizationService.summarize(
            transcript: text,
            backend: llmBackend,
            model: cfg.llmModel,
            ollamaHost: cfg.ollamaHost,
            prompt: prompt
        )

        try summary.write(to: outURL, atomically: true, encoding: .utf8)
        print("Summary: \(outURL.path)")
    }
}

// MARK: - run

struct Run: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Record → transcribe → summarize in one shot."
    )

    @Option(name: .shortAndLong, help: "Recording duration in seconds.")
    var duration: Int?

    @Option(name: .long, help: "Language code: he, en, auto.")
    var lang: String?

    @Flag(name: .long, help: "Skip speaker diarization.")
    var noDiarize = false

    @Option(
        name: .long,
        help: "Number of distinct speakers. Overrides config; 0 = auto-detect."
    )
    var numSpeakers: Int?

    @Flag(name: .long, help: "Skip summarization.")
    var noSummarize = false

    func validate() throws {
        if let ns = numSpeakers, ns < 0 {
            throw ValidationError("--num-speakers must be >= 0 (0 means auto-detect).")
        }
    }

    @Option(name: .long, help: "Named prompt profile from ~/.transcribeer/prompts/.")
    var profile: String?

    func run() async throws {
        let cfg = ConfigManager.load()
        let sess = SessionManager.newSession(sessionsDir: cfg.expandedSessionsDir)
        let audioPath = sess.appendingPathComponent("audio.m4a")
        let txPath = sess.appendingPathComponent("transcript.txt")
        let summaryPath = sess.appendingPathComponent("summary.md")

        print("Session: \(sess.path)")

        // 1. Record
        print("\nStep 1/3 — Recording")
        if let d = duration { print("  Auto-stop after \(d)s.") } else { print("  Press Ctrl+C to stop.") }
        try runCapture(captureBin: cfg.expandedCaptureBin, audioPath: audioPath.path, duration: duration, pidFile: nil)

        // 2. Transcribe
        print("\nStep 2/3 — Transcribing")
        let language = lang ?? cfg.language
        let text = try await transcribeAndFormat(
            audioURL: audioPath,
            language: language,
            diarization: noDiarize ? "none" : cfg.diarization,
            numSpeakers: resolveNumSpeakers(override: numSpeakers, config: cfg.numSpeakers),
            cfg: cfg
        )
        try text.write(to: txPath, atomically: true, encoding: .utf8)
        print("  Transcript: \(txPath.path)")

        if noSummarize {
            print("\nDone. Session: \(sess.path)")
            return
        }

        // 3. Summarize
        print("\nStep 3/3 — Summarizing")
        let prompt = SummarizationService.loadPromptProfile(profile)
        do {
            let summary = try await SummarizationService.summarize(
                transcript: text,
                backend: cfg.llmBackend,
                model: cfg.llmModel,
                ollamaHost: cfg.ollamaHost,
                prompt: prompt
            )
            try summary.write(to: summaryPath, atomically: true, encoding: .utf8)
            print("  Summary: \(summaryPath.path)")
        } catch {
            print("  Summarization skipped: \(error.localizedDescription)")
        }

        print("\nDone. Session: \(sess.path)")
    }
}

// MARK: - Shared helpers

private func runCapture(captureBin: String, audioPath: String, duration: Int?, pidFile: String?) throws {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: captureBin)
    var args = [audioPath]
    if let d = duration { args.append(String(d)) }
    proc.arguments = args

    let errPipe = Pipe()
    proc.standardError = errPipe

    do {
        try proc.run()
    } catch {
        throw CLIError.captureFailed("Failed to launch capture-bin: \(error.localizedDescription)")
    }

    if let pidFile {
        try String(proc.processIdentifier).write(
            toFile: (pidFile as NSString).expandingTildeInPath,
            atomically: true,
            encoding: .utf8
        )
    }

    proc.waitUntilExit()

    if proc.terminationStatus != 0 {
        let stderr = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        if stderr.contains("Screen & System Audio Recording") {
            throw CLIError.captureFailed("Grant Screen Recording in System Settings → Privacy & Security.")
        }
        throw CLIError.captureFailed("capture-bin exited \(proc.terminationStatus)")
    }
}

/// Resolve the effective speaker count by preferring the CLI override over the
/// config value. `0` in either layer means "auto-detect" and maps to `nil`.
private func resolveNumSpeakers(override: Int?, config: Int) -> Int? {
    if let override {
        return override > 0 ? override : nil
    }
    return config > 0 ? config : nil
}

private func transcribeAndFormat(
    audioURL: URL,
    language: String,
    diarization: String,
    numSpeakers: Int?,
    cfg: AppConfig
) async throws -> String {
    // Guard: fail fast on silent recordings (e.g. SCStream captured nothing).
    // Saves 5-10 min of wasted WhisperKit CPU on a guaranteed empty transcript.
    try AudioValidation.ensureAudibleSignal(at: audioURL)

    print("  Loading model \(cfg.whisperModel)…")
    let whisperSegments = try await transcribeAudio(
        audioURL: audioURL,
        language: language,
        modelName: cfg.whisperModel,
        modelsDir: AppConfig.modelsDir,
        onProgress: { pct in
            let bar = Int(pct * 20)
            let filled = String(repeating: "█", count: bar)
            let empty = String(repeating: "░", count: 20 - bar)
            print("  [\(filled)\(empty)] \(Int(pct * 100))%", terminator: "\r")
            fflush(stdout)
        }
    )
    print()

    let diarSegments: [DiarSegment]
    if diarization == "none" {
        diarSegments = []
    } else {
        print("  Diarizing speakers…")
        diarSegments = (try? await DiarizationService.diarize(
            audioURL: audioURL,
            numSpeakers: numSpeakers
        )) ?? []
    }

    let labeled = TranscriptFormatter.assignSpeakers(
        whisperSegments: whisperSegments,
        diarSegments: diarSegments
    )
    return TranscriptFormatter.format(labeled)
}

enum CLIError: LocalizedError {
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .captureFailed(let msg): return msg
        }
    }
}
