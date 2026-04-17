import Foundation
import os.log

/// Import the user's shell environment so exports from `~/.zshrc` (or the
/// equivalent for bash/fish) are visible when the app is launched from Finder
/// or launchd, which otherwise start with a near-empty environment.
enum ShellEnvironment {
    private static let logger = Logger(subsystem: "com.transcribeer", category: "shell-env")

    /// Shell invocation flags by shell name. Must include `-i` (interactive) so
    /// zsh sources `~/.zshrc` — `-l` alone only reads `~/.zprofile`. bash uses
    /// different rules but `-l -i` is the safe superset. fish ignores both.
    private static let flagsByShell: [String: [String]] = [
        "zsh": ["-l", "-i", "-c", "env"],
        "bash": ["-l", "-i", "-c", "env"],
        "fish": ["-l", "-c", "env"],
    ]

    static func load() {
        let shellPath = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shellPath as NSString).lastPathComponent
        let args = flagsByShell[shellName] ?? ["-l", "-i", "-c", "env"]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shellPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            logger.error("Failed to spawn \(shellPath): \(error.localizedDescription)")
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }

        var imported = 0
        let current = ProcessInfo.processInfo.environment
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eqIdx = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eqIdx])
            let value = String(line[line.index(after: eqIdx)...])
            if current[key] == nil {
                setenv(key, value, 0)
                imported += 1
            }
        }
        logger.info("Imported \(imported) env vars from \(shellName) (\(args.joined(separator: " ")))")
    }
}
