import TranscribeerCore
import Foundation

/// Load login shell environment so API keys from ~/.zshrc are available.
enum ShellEnvironment {
    static func load() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-l", "-c", "env"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }

        let current = ProcessInfo.processInfo.environment
        for line in output.components(separatedBy: "\n") {
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eqIdx])
            let value = String(line[line.index(after: eqIdx)...])
            if current[key] == nil {
                setenv(key, value, 0)
            }
        }
    }
}
