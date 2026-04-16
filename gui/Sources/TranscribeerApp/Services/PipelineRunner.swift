import Foundation
import os.log
import TranscribeerCore

private let logger = Logger(subsystem: "com.transcribeer", category: "pipeline")

/// Runs the transcribeer pipeline using native Swift services.
@Observable
@MainActor
final class PipelineRunner {
    var state: AppState = .idle
    var currentSession: URL?
    var promptProfile: String?

    /// True when the current recording was auto-started by Zoom detection.
    var zoomAutoStarted = false

    /// Transcription progress (0..1), driven by WhisperKit.
    var transcriptionProgress: Double? { transcriptionService.progress }

    let transcriptionService = TranscriptionService()

    private var captureProcess: Process?
    private var pipelineTask: Task<Void, Never>?

    func startRecording(config: AppConfig) {
        guard !state.isBusy else { return }

        let session = SessionManager.newSession(sessionsDir: config.expandedSessionsDir)
        currentSession = session
        promptProfile = nil
        state = .recording(startTime: Date())

        pipelineTask = Task {
            await runPipeline(session: session, config: config)
        }
    }

    func stopRecording() {
        guard state.isRecording else { return }
        if let proc = captureProcess, proc.isRunning {
            proc.interrupt()  // SIGINT
        }
    }

    private func runPipeline(session: URL, config: AppConfig) async {
        let audioPath = session.appendingPathComponent("audio.wav")
        let transcriptPath = session.appendingPathComponent("transcript.txt")
        let summaryPath = session.appendingPathComponent("summary.md")
        let logPath = session.appendingPathComponent("run.log")

        func log(_ msg: String) {
            let ts = DateFormatter.localizedString(
                from: Date(), dateStyle: .none, timeStyle: .medium
            )
            let line = "[\(ts)] \(msg)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logPath.path) {
                    if let handle = try? FileHandle(forWritingTo: logPath) {
                        handle.seekToEndOfFile()
                        handle.write(data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: logPath)
                }
            }
        }

        log("session=\(session.path)")
        log("pipeline=\(config.pipelineMode) lang=\(config.language) diarize=\(config.diarization)")

        // 1. Record — use capture-bin directly
        log("capture-bin=\(config.expandedCaptureBin)")
        let recordResult = await runCapture(
            captureBin: config.expandedCaptureBin,
            audioPath: audioPath
        )

        switch recordResult {
        case .error(let err):
            log("capture failed: \(err)")
            state = .error(err)
            NotificationManager.notifyError(err)
            return
        case .noAudio:
            log("no audio captured")
            state = .idle
            return
        case .recorded:
            let size = (try? FileManager.default.attributesOfItem(
                atPath: audioPath.path
            )[.size] as? Int ?? 0) ?? 0
            log("recorded \(size) bytes")
        }

        if config.pipelineMode == "record-only" {
            state = .done(sessionPath: session.path)
            NotificationManager.notifyDone(sessionName: SessionManager.displayName(session))
            return
        }

        // 2. Transcribe (WhisperKit + SpeakerKit)
        state = .transcribing
        log("transcription started")

        do {
            let result = try await transcribeAndFormat(
                audioPath: audioPath,
                language: config.language,
                model: config.whisperModel,
                diarization: config.diarization,
                numSpeakers: config.numSpeakers
            )
            try result.write(to: transcriptPath, atomically: true, encoding: .utf8)
            log("transcription done")
        } catch {
            let err = "Transcription failed: \(error.localizedDescription)"
            log(err)
            state = .error(err)
            NotificationManager.notifyError(err)
            return
        }

        if config.pipelineMode == "record+transcribe" {
            state = .done(sessionPath: session.path)
            NotificationManager.notifyDone(sessionName: SessionManager.displayName(session))
            return
        }

        // 3. Summarize (LLM)
        state = .summarizing
        log("summarization started backend=\(config.llmBackend) model=\(config.llmModel) profile=\(promptProfile ?? "default")")

        do {
            let transcript = try String(contentsOf: transcriptPath, encoding: .utf8)
            let customPrompt = SummarizationService.loadPromptProfile(promptProfile)
            let summary = try await SummarizationService.summarize(
                transcript: transcript,
                backend: config.llmBackend,
                model: config.llmModel,
                ollamaHost: config.ollamaHost,
                prompt: customPrompt
            )
            try summary.write(to: summaryPath, atomically: true, encoding: .utf8)
            log("summarization done")
        } catch {
            log("summarization failed: \(error.localizedDescription)")
            // Done anyway — transcript is what matters
        }

        state = .done(sessionPath: session.path)
        NotificationManager.notifyDone(sessionName: SessionManager.displayName(session))
    }

    // MARK: - Transcription + Diarization + Formatting

    private func transcribeAndFormat(
        audioPath: URL,
        language: String,
        model: String,
        diarization: String,
        numSpeakers: Int
    ) async throws -> String {
        // Ensure the configured model is loaded
        try await transcriptionService.loadModel(name: model)

        // Run transcription
        let whisperSegments = try await transcriptionService.transcribe(
            audioURL: audioPath,
            language: language
        )

        // Run diarization (unless disabled)
        let diarSegments: [DiarSegment]
        if diarization == "none" {
            diarSegments = []
        } else {
            diarSegments = try await DiarizationService.diarize(
                audioURL: audioPath,
                numSpeakers: numSpeakers > 0 ? numSpeakers : nil
            )
        }

        // Merge and format
        let labeled = TranscriptFormatter.assignSpeakers(
            whisperSegments: whisperSegments,
            diarSegments: diarSegments
        )
        return TranscriptFormatter.format(labeled)
    }

    // MARK: - Capture

    private enum CaptureResult {
        case recorded
        case noAudio
        case error(String)
    }

    private func runCapture(captureBin: String, audioPath: URL) async -> CaptureResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: captureBin)
                proc.arguments = [audioPath.path]
                let errPipe = Pipe()
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = errPipe

                do {
                    try proc.run()
                } catch {
                    continuation.resume(returning: .error(
                        "Failed to launch capture-bin: \(error.localizedDescription)"
                    ))
                    return
                }

                Task { @MainActor in
                    self?.captureProcess = proc
                }

                proc.waitUntilExit()

                Task { @MainActor in
                    self?.captureProcess = nil
                }

                let stderr = String(
                    data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""

                if proc.terminationStatus != 0 {
                    if stderr.contains("Screen & System Audio Recording") {
                        continuation.resume(returning: .error(
                            "Grant Screen Recording in System Settings → Privacy"
                        ))
                    } else {
                        continuation.resume(returning: .error(
                            "capture-bin exited \(proc.terminationStatus)"
                        ))
                    }
                    return
                }

                let exists = FileManager.default.fileExists(atPath: audioPath.path)
                let size = (try? FileManager.default.attributesOfItem(
                    atPath: audioPath.path
                )[.size] as? UInt64) ?? 0
                if exists && size > 0 {
                    continuation.resume(returning: .recorded)
                } else {
                    continuation.resume(returning: .noAudio)
                }
            }
        }
    }

    // MARK: - History re-runs

    /// Result of a pipeline operation.
    struct CLIResult {
        let ok: Bool
        let error: String
    }

    /// Re-transcribe a session from its audio.
    func transcribeSession(_ session: URL, config: AppConfig) async -> CLIResult {
        let audioPath = session.appendingPathComponent("audio.wav")
        let txPath = session.appendingPathComponent("transcript.txt")

        guard FileManager.default.fileExists(atPath: audioPath.path) else {
            return CLIResult(ok: false, error: "Audio file not found")
        }

        logger.info("re-transcribe: \(audioPath.path)")

        do {
            let result = try await transcribeAndFormat(
                audioPath: audioPath,
                language: config.language,
                model: config.whisperModel,
                diarization: config.diarization,
                numSpeakers: config.numSpeakers
            )
            try result.write(to: txPath, atomically: true, encoding: .utf8)
            return CLIResult(ok: true, error: "")
        } catch {
            logger.error("re-transcribe failed: \(error.localizedDescription)")
            return CLIResult(ok: false, error: error.localizedDescription)
        }
    }

    /// Re-summarize a session from its transcript.
    func summarizeSession(
        _ session: URL,
        config: AppConfig,
        profile: String?
    ) async -> CLIResult {
        let txPath = session.appendingPathComponent("transcript.txt")
        let smPath = session.appendingPathComponent("summary.md")

        guard FileManager.default.fileExists(atPath: txPath.path) else {
            return CLIResult(ok: false, error: "Transcript file not found")
        }

        logger.info("re-summarize: \(txPath.path)")

        do {
            let transcript = try String(contentsOf: txPath, encoding: .utf8)
            let customPrompt = SummarizationService.loadPromptProfile(profile)
            let summary = try await SummarizationService.summarize(
                transcript: transcript,
                backend: config.llmBackend,
                model: config.llmModel,
                ollamaHost: config.ollamaHost,
                prompt: customPrompt
            )
            try summary.write(to: smPath, atomically: true, encoding: .utf8)
            return CLIResult(ok: true, error: "")
        } catch {
            logger.error("re-summarize failed: \(error.localizedDescription)")
            return CLIResult(ok: false, error: error.localizedDescription)
        }
    }
}
