import Foundation

enum AppState {
    case idle
    case recording
    case transcribing
    case summarizing
    case done(sessionPath: String)
    case error(String)
}

class TranscribeeRunner: ObservableObject {
    @Published var state: AppState = .idle

    private var process: Process?

    // MARK: - Binary discovery

    private func findBinary() -> String? {
        let candidates = [
            (NSString("~/.local/bin/transcribee").expandingTildeInPath),
            "/usr/local/bin/transcribee",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Public API

    func start() {
        guard let binaryPath = findBinary() else {
            DispatchQueue.main.async {
                self.state = .error("transcribee not installed — run install.sh")
            }
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["run"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // readabilityHandler fires whenever data is available — no busy-loop.
        // `buf` is captured by the closure and persists across partial reads.
        func attachReader(to pipe: Pipe) {
            var buf = Data()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    handle.readabilityHandler = nil
                    return
                }
                buf.append(chunk)
                while let nl = buf.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buf[buf.startIndex..<nl]
                    buf.removeSubrange(buf.startIndex...nl)
                    if let line = String(data: lineData, encoding: .utf8) {
                        self.handleLine(line)
                    }
                }
            }
        }

        attachReader(to: stdoutPipe)
        attachReader(to: stderrPipe)

        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            let code = p.terminationStatus
            DispatchQueue.main.async {
                if code == 0 {
                    // done was already set via output parsing; no-op
                    if case .done = self.state { return }
                    // else: normal exit without session line — no-op
                } else {
                    if case .error = self.state { return }
                    self.state = .error("capture exited \(code)")
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
            DispatchQueue.main.async {
                self.state = .recording
            }
        } catch {
            DispatchQueue.main.async {
                self.state = .error("Failed to launch transcribee: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        process?.interrupt()
    }

    // MARK: - Output parsing

    private func handleLine(_ line: String) {
        let lower = line.lowercased()

        if line.contains("Step 2/3") || line.contains("Transcribing") {
            DispatchQueue.main.async { self.state = .transcribing }
        } else if line.contains("Step 3/3") || line.contains("Summarizing") {
            DispatchQueue.main.async { self.state = .summarizing }
        } else if line.contains("Session:") {
            let sessionPath = extractSessionPath(from: line)
            DispatchQueue.main.async {
                self.state = .done(sessionPath: sessionPath)
                NotificationManager.notifyDone(sessionPath: sessionPath)
            }
        } else if line.contains("Permission denied") || line.contains("Grant") {
            DispatchQueue.main.async {
                self.state = .error("Screen recording permission required")
                NotificationManager.notifyError("Screen recording permission required")
            }
        } else if lower.contains("failed") {
            DispatchQueue.main.async {
                self.state = .error(line)
                NotificationManager.notifyError(line)
            }
        }
    }

    private func extractSessionPath(from line: String) -> String {
        if let range = line.range(of: "Session: ") {
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
