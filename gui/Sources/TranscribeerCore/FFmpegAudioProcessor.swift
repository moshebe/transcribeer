import Foundation

/// Audio-processing backend that wraps the `ffmpeg` command-line tool.
public struct FFmpegAudioProcessor: AudioProcessingBackend {
    public let backendID = "ffmpeg"

    private static let maxFailureDetailLength = 4_000

    private let configuredPath: String
    private let environment: [String: String]
    private let homeDirectory: URL
    private let isExecutable: @Sendable (String) -> Bool
    private let runner: any FFmpegCommandRunning

    public init(configuredPath: String = "") {
        self.init(
            configuredPath: configuredPath,
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            isExecutable: { path in FileManager.default.isExecutableFile(atPath: path) },
            runner: ProcessFFmpegCommandRunner()
        )
    }

    init(
        configuredPath: String,
        environment: [String: String],
        homeDirectory: URL,
        isExecutable: @escaping @Sendable (String) -> Bool,
        runner: any FFmpegCommandRunning
    ) {
        self.configuredPath = configuredPath
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.isExecutable = isExecutable
        self.runner = runner
    }

    public func availability() async -> AudioProcessingBackendAvailability {
        guard let executableURL = resolvedExecutableURL() else {
            return .unavailable(backendID: backendID, reason: unavailableReason())
        }
        return .available(backendID: backendID, executableURL: executableURL)
    }

    public func transcode(_ request: AudioTranscodeRequest) async throws -> AudioTranscodeResult {
        guard let executableURL = resolvedExecutableURL() else {
            throw AudioProcessingError.backendUnavailable(await availability())
        }
        guard fileExists(request.inputURL) else {
            throw AudioProcessingError.inputMissing(request.inputURL)
        }

        let inputBytes = SourceAudioFiles.byteCount(request.inputURL)
        let tempURL = AudioTranscodeIO.temporaryOutputURL(for: request.outputURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let arguments = commandArguments(for: request, outputURL: tempURL)
        let commandResult = try await runCommand(
            executableURL,
            arguments: arguments,
            request: request,
            tempURL: tempURL
        )
        guard commandResult.terminationStatus == 0 else {
            throw commandFailed(
                commandResult,
                executableURL: executableURL,
                request: request,
                tempURL: tempURL
            )
        }
        guard SourceAudioFiles.isNonEmpty(tempURL) else {
            throw AudioProcessingError.emptyOutput(request.outputURL)
        }

        try AudioTranscodeIO.replace(tempURL: tempURL, outputURL: request.outputURL)
        return AudioTranscodeResult(
            outputURL: request.outputURL,
            backendID: backendID,
            outputBytes: SourceAudioFiles.byteCount(request.outputURL),
            inputBytes: inputBytes
        )
    }

    func resolvedExecutableURL() -> URL? {
        candidatePaths()
            .first(where: isExecutable)
            .map { URL(fileURLWithPath: $0) }
    }

    func commandArguments(for request: AudioTranscodeRequest, outputURL: URL) -> [String] {
        var arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-i", request.inputURL.path,
            "-map", "0:a:0", "-vn",
        ]
        arguments.append(contentsOf: ["-ac", "1"])
        if let sampleRate = request.sampleRate {
            arguments.append(contentsOf: ["-ar", sampleRateArgument(sampleRate)])
        }
        arguments.append(contentsOf: ["-c:a", "aac"])
        if let bitrate = request.bitrate {
            arguments.append(contentsOf: ["-b:a", bitrateArgument(bitrate)])
        }
        arguments.append(contentsOf: ["-movflags", "+faststart", outputURL.path])
        return arguments
    }

    private func runCommand(
        _ executableURL: URL,
        arguments: [String],
        request: AudioTranscodeRequest,
        tempURL: URL
    ) async throws -> FFmpegCommandResult {
        do {
            return try await runner.run(executableURL: executableURL, arguments: arguments)
        } catch {
            let detail = sanitizedFailureDetail(
                error.localizedDescription,
                executableURL: executableURL,
                request: request,
                tempURL: tempURL
            )
            throw AudioProcessingError.commandFailed(
                backendID: backendID,
                exitCode: nil,
                message: detail
            )
        }
    }

    private func commandFailed(
        _ result: FFmpegCommandResult,
        executableURL: URL,
        request: AudioTranscodeRequest,
        tempURL: URL
    ) -> AudioProcessingError {
        AudioProcessingError.commandFailed(
            backendID: backendID,
            exitCode: result.terminationStatus,
            message: sanitizedFailureDetail(
                result.standardError,
                executableURL: executableURL,
                request: request,
                tempURL: tempURL
            )
        )
    }

    private func candidatePaths() -> [String] {
        let configured = expand(configuredPath.trimmingCharacters(in: .whitespacesAndNewlines))
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/ffmpeg" }
        return ([configured] + pathCandidates + commonPaths()).filter { !$0.isEmpty }
    }

    private func commonPaths() -> [String] {
        [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            homeDirectory.appendingPathComponent(".transcribeer/bin/ffmpeg").path,
        ]
    }

    private func expand(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        if path == "~" { return homeDirectory.path }
        guard path.hasPrefix("~/") else { return path }
        return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
    }

    private func unavailableReason() -> String {
        let configured = expand(configuredPath.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !configured.isEmpty else { return "ffmpeg executable was not found" }
        return "configured ffmpeg is not executable: \(configured)"
    }

    private func sanitizedFailureDetail(
        _ detail: String,
        executableURL: URL,
        request: AudioTranscodeRequest,
        tempURL: URL
    ) -> String? {
        var sanitized = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return nil }
        for redaction in redactions(executableURL: executableURL, request: request, tempURL: tempURL) {
            sanitized = sanitized.replacingOccurrences(of: redaction.path, with: redaction.placeholder)
        }
        return String(sanitized.prefix(Self.maxFailureDetailLength))
    }

    private func redactions(
        executableURL: URL,
        request: AudioTranscodeRequest,
        tempURL: URL
    ) -> [(path: String, placeholder: String)] {
        [
            (executableURL.path, "<ffmpeg>"),
            (request.inputURL.path, "<input>"),
            (request.outputURL.path, "<output>"),
            (tempURL.path, "<temp>"),
        ]
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func fileSize(_ url: URL) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return 0
        }
        return switch attributes[.size] {
        case let size as UInt64: size
        case let size as NSNumber: size.uint64Value
        default: 0
        }
    }
}

protocol FFmpegCommandRunning: Sendable {
    func run(executableURL: URL, arguments: [String]) async throws -> FFmpegCommandResult
}

struct FFmpegCommandResult: Sendable, Equatable {
    let terminationStatus: Int32
    let standardError: String
}

struct ProcessFFmpegCommandRunner: FFmpegCommandRunning {
    func run(executableURL: URL, arguments: [String]) async throws -> FFmpegCommandResult {
        try await Task.detached(priority: .utility) {
            try Self.runSynchronously(executableURL: executableURL, arguments: arguments)
        }.value
    }

    private static func runSynchronously(
        executableURL: URL,
        arguments: [String]
    ) throws -> FFmpegCommandResult {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        return FFmpegCommandResult(
            terminationStatus: process.terminationStatus,
            standardError: String(data: errorData, encoding: .utf8) ?? ""
        )
    }
}

private func sampleRateArgument(_ sampleRate: Double) -> String {
    let rounded = sampleRate.rounded()
    if sampleRate == rounded { return String(Int(rounded)) }
    return String(sampleRate)
}

private func bitrateArgument(_ bitrate: Int) -> String {
    guard bitrate.isMultiple(of: 1_000) else { return String(bitrate) }
    return "\(bitrate / 1_000)k"
}
