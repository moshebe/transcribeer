import Foundation

/// Reads Google Cloud Application Default Credentials via the `gcloud` CLI.
///
/// Transcribeer uses Vertex AI's OpenAI-compatible endpoint for Gemini, which
/// requires an OAuth access token tied to a GCP project — not a raw API key.
/// Shelling out to gcloud avoids bundling the Google auth libs just for this.
enum GCloudAuth {
    /// Snapshot of the currently configured gcloud state.
    struct Status: Sendable, Equatable {
        var gcloudAvailable: Bool
        var account: String?        // e.g. kostya@example.com
        var project: String?        // e.g. my-gcp-project
        var hasADC: Bool            // application_default_credentials.json present

        var isReady: Bool {
            gcloudAvailable && hasADC && project != nil
        }
    }

    /// Default Vertex AI region; users on other regions can override via config.
    static let defaultRegion = "us-central1"

    /// Candidate gcloud install locations, searched in order. PATH is checked
    /// last because GUI apps launched from Finder don't inherit shell PATH.
    private static let gcloudCandidates = [
        "/opt/homebrew/bin/gcloud",
        "/usr/local/bin/gcloud",
        "/usr/bin/gcloud",
    ]

    /// Locate the gcloud binary, or return `nil` if it isn't installed.
    static func locateGCloud() -> URL? {
        let fm = FileManager.default
        if let hit = gcloudCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: hit)
        }
        let pathDirs = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
        for dir in pathDirs {
            let candidate = "\(dir)/gcloud"
            if fm.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Probe gcloud for the current login + ADC state.
    static func status() async -> Status {
        guard let gcloud = locateGCloud() else {
            return Status(gcloudAvailable: false, account: nil, project: nil, hasADC: false)
        }
        async let account = run(gcloud, ["config", "get-value", "account"])
        async let project = run(gcloud, ["config", "get-value", "project"])
        let (accountOut, projectOut) = await (account, project)

        let adcPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/gcloud/application_default_credentials.json")
        let hasADC = FileManager.default.fileExists(atPath: adcPath.path)

        return Status(
            gcloudAvailable: true,
            account: accountOut.trimmedNonEmpty,
            project: projectOut.trimmedNonEmpty,
            hasADC: hasADC
        )
    }

    /// Fetch a fresh ADC access token. Throws if gcloud is missing or the user
    /// has not run `gcloud auth application-default login`.
    static func accessToken() throws -> String {
        guard let gcloud = locateGCloud() else { throw GCloudError.gcloudNotFound }
        let output = try runSync(gcloud, ["auth", "application-default", "print-access-token"])
        let token = output.trimmedNonEmpty
        guard let token else { throw GCloudError.adcMissing }
        return token
    }

    /// Return the current GCP project id, or throw if gcloud is not configured.
    static func project() throws -> String {
        guard let gcloud = locateGCloud() else { throw GCloudError.gcloudNotFound }
        let output = try runSync(gcloud, ["config", "get-value", "project"])
        guard let project = output.trimmedNonEmpty else { throw GCloudError.projectMissing }
        return project
    }

    // MARK: - Subprocess helpers

    /// Run `tool args` off the current actor, returning stdout (empty on failure).
    private static func run(_ tool: URL, _ args: [String]) async -> String {
        await Task.detached(priority: .userInitiated) {
            (try? runSync(tool, args)) ?? ""
        }.value
    }

    /// Synchronous subprocess runner. Discards stderr; throws on non-zero exit.
    private static func runSync(_ tool: URL, _ args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = tool
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw GCloudError.commandFailed(tool.lastPathComponent, args, proc.terminationStatus)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum GCloudError: LocalizedError {
    case gcloudNotFound
    case adcMissing
    case projectMissing
    case commandFailed(String, [String], Int32)

    var errorDescription: String? {
        switch self {
        case .gcloudNotFound:
            return "gcloud CLI not found. Install the Google Cloud SDK to use Gemini."
        case .adcMissing:
            return "No Application Default Credentials. Run: gcloud auth application-default login"
        case .projectMissing:
            return "No GCP project configured. Run: gcloud config set project <your-project>"
        case let .commandFailed(cmd, args, code):
            let joined = args.joined(separator: " ")
            return "\(cmd) \(joined) exited with code \(code)"
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
