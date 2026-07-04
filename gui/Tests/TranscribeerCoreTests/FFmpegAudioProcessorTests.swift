import Foundation
import Testing
@testable import TranscribeerCore

struct FFmpegAudioProcessorTests {
    @Test("Resolver uses executable configured path before PATH and common paths")
    func resolverUsesConfiguredPathFirst() {
        let home = URL(fileURLWithPath: "/tmp/transcribeer-home", isDirectory: true)
        let configured = home.appendingPathComponent("custom/ffmpeg").path
        let pathFFmpeg = "/tmp/path-bin/ffmpeg"
        let processor = makeProcessor(
            configuredPath: "~/custom/ffmpeg",
            environment: ["PATH": "/tmp/path-bin"],
            homeDirectory: home,
            executablePaths: [configured, pathFFmpeg]
        )

        #expect(processor.resolvedExecutableURL()?.path == configured)
    }

    @Test("Resolver skips missing configured path and searches PATH")
    func resolverSkipsMissingConfiguredPath() {
        let home = URL(fileURLWithPath: "/tmp/transcribeer-home", isDirectory: true)
        let pathFFmpeg = "/tmp/second-bin/ffmpeg"
        let processor = makeProcessor(
            configuredPath: "/missing/ffmpeg",
            environment: ["PATH": "/tmp/first-bin:/tmp/second-bin"],
            homeDirectory: home,
            executablePaths: [pathFFmpeg]
        )

        #expect(processor.resolvedExecutableURL()?.path == pathFFmpeg)
    }

    @Test("Resolver searches user-managed ffmpeg after PATH")
    func resolverSearchesTranscribeerBin() {
        let home = URL(fileURLWithPath: "/tmp/transcribeer-home", isDirectory: true)
        let userManaged = home.appendingPathComponent(".transcribeer/bin/ffmpeg").path
        let processor = makeProcessor(
            environment: ["PATH": "/tmp/empty-bin"],
            homeDirectory: home,
            executablePaths: [userManaged]
        )

        #expect(processor.resolvedExecutableURL()?.path == userManaged)
    }

    @Test("Availability reports unavailable when configured path and fallbacks are missing")
    func availabilityReportsMissingExecutable() async {
        let processor = makeProcessor(
            configuredPath: "/missing/ffmpeg",
            environment: ["PATH": "/tmp/empty-bin"],
            executablePaths: []
        )

        let availability = await processor.availability()

        #expect(availability.isAvailable == false)
        #expect(availability.executableURL == nil)
        #expect(availability.reason?.contains("/missing/ffmpeg") == true)
    }

    @Test("Transcode builds sidecar-compatible ffmpeg arguments and replaces through a temp file")
    func transcodeBuildsArgumentsAndReplacesOutput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("audio.mic.caf")
        let output = directory.appendingPathComponent("audio.mic.m4a")
        let inputData = Data("caf-input".utf8)
        try inputData.write(to: input)
        try Data("old-output".utf8).write(to: output)

        let executable = "/opt/test/bin/ffmpeg"
        let spy = FFmpegRunnerSpy()
        let processor = makeProcessor(executablePaths: [executable], runner: StubFFmpegRunner(spy: spy))
        let request = AudioTranscodeRequest(inputURL: input, outputURL: output)

        let result = try await processor.transcode(request)
        let call = try await #require(spy.lastCall())
        let tempPath = try #require(call.arguments.last)

        #expect(call.executableURL.path == executable)
        #expect(Array(call.arguments.dropLast()) == expectedDefaultArguments(input: input))
        #expect(tempPath != output.path)
        #expect(tempPath.hasSuffix(".m4a"))
        #expect(try Data(contentsOf: output) == FFmpegRunnerSpy.outputData)
        #expect(result.outputURL == output)
        #expect(result.backendID == "ffmpeg")
        #expect(result.outputBytes == UInt64(FFmpegRunnerSpy.outputData.count))
        #expect(result.inputBytes == UInt64(inputData.count))
    }

    @Test("Transcode failure preserves stderr detail while redacting local paths")
    func transcodeFailureSanitizesCommandDetail() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("private-input.caf")
        let output = directory.appendingPathComponent("private-output.m4a")
        try Data("caf-input".utf8).write(to: input)

        let executable = "/opt/test/bin/ffmpeg"
        let spy = FFmpegRunnerSpy(result: .init(
            terminationStatus: 7,
            standardError: "Could not decode \(input.path); output \(output.path) was not written"
        ), writesOutput: false)
        let processor = makeProcessor(executablePaths: [executable], runner: StubFFmpegRunner(spy: spy))
        let request = AudioTranscodeRequest(inputURL: input, outputURL: output)

        do {
            _ = try await processor.transcode(request)
            Issue.record("Expected ffmpeg command failure")
        } catch let error as AudioProcessingError {
            guard case let .commandFailed(backendID, exitCode, message) = error else {
                Issue.record("Expected commandFailed, got \(error)")
                return
            }
            #expect(backendID == "ffmpeg")
            #expect(exitCode == 7)
            #expect(message?.contains("Could not decode <input>") == true)
            #expect(message?.contains(input.path) == false)
            #expect(message?.contains(output.path) == false)
        }
    }
}

private struct FFmpegCommandCall: Sendable, Equatable {
    let executableURL: URL
    let arguments: [String]
}

private actor FFmpegRunnerSpy {
    static let outputData = Data("m4a-output".utf8)

    private var calls: [FFmpegCommandCall] = []
    private let result: FFmpegCommandResult
    private let writesOutput: Bool

    init(
        result: FFmpegCommandResult = .init(terminationStatus: 0, standardError: ""),
        writesOutput: Bool = true
    ) {
        self.result = result
        self.writesOutput = writesOutput
    }

    func run(executableURL: URL, arguments: [String]) throws -> FFmpegCommandResult {
        calls.append(FFmpegCommandCall(executableURL: executableURL, arguments: arguments))
        if writesOutput, let outputPath = arguments.last {
            try Self.outputData.write(to: URL(fileURLWithPath: outputPath))
        }
        return result
    }

    func lastCall() -> FFmpegCommandCall? {
        calls.last
    }
}

private struct StubFFmpegRunner: FFmpegCommandRunning {
    let spy: FFmpegRunnerSpy

    func run(executableURL: URL, arguments: [String]) async throws -> FFmpegCommandResult {
        try await spy.run(executableURL: executableURL, arguments: arguments)
    }
}

private struct NoopFFmpegRunner: FFmpegCommandRunning {
    func run(executableURL: URL, arguments: [String]) async throws -> FFmpegCommandResult {
        FFmpegCommandResult(terminationStatus: 0, standardError: "")
    }
}

private func makeProcessor(
    configuredPath: String = "",
    environment: [String: String] = ["PATH": "/opt/test/bin"],
    homeDirectory: URL = URL(fileURLWithPath: "/tmp/transcribeer-home", isDirectory: true),
    executablePaths: Set<String>,
    runner: any FFmpegCommandRunning = NoopFFmpegRunner()
) -> FFmpegAudioProcessor {
    FFmpegAudioProcessor(
        configuredPath: configuredPath,
        environment: environment,
        homeDirectory: homeDirectory,
        isExecutable: { executablePaths.contains($0) },
        runner: runner
    )
}

private func expectedDefaultArguments(input: URL) -> [String] {
    [
        "-hide_banner", "-loglevel", "error", "-y",
        "-i", input.path,
        "-map", "0:a:0", "-vn",
        "-ac", "1", "-ar", "16000",
        "-c:a", "aac", "-b:a", "48k",
        "-movflags", "+faststart",
    ]
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("FFmpegAudioProcessorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
