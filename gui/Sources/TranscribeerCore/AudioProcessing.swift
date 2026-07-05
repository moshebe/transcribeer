import Foundation

/// Common contract for audio-processing backends.
///
/// Concrete implementations can wrap command-line tools such as ffmpeg or
/// native macOS frameworks. The protocol intentionally models only the work
/// the app currently needs: probing backend availability and transcoding one
/// file to another.
public protocol AudioProcessingBackend: Sendable {
    /// Stable identifier used in logs, reports, and test expectations.
    var backendID: String { get }

    /// Resolves whether this backend can currently run on this machine.
    func availability() async -> AudioProcessingBackendAvailability

    /// Transcodes `request.inputURL` into `request.outputURL`.
    func transcode(_ request: AudioTranscodeRequest) async throws -> AudioTranscodeResult
}

/// Audio codec requested for transcode output.
public enum AudioProcessingCodec: String, CaseIterable, Sendable, Equatable {
    /// AAC-LC, used by compact M4A sidecars and cloud-upload chunks.
    case aac
}

/// Container requested for transcode output.
public enum AudioProcessingContainer: String, CaseIterable, Sendable, Equatable {
    /// MPEG-4 audio container, normally with an `.m4a` extension.
    case m4a

    /// Default file extension for this container.
    public var fileExtension: String { rawValue }
}

/// Channel layout requested for transcode output.
public enum AudioProcessingChannelMode: Sendable, Equatable {
    /// Keep the backend/source default channel layout.
    case preserve
    /// Downmix to one channel.
    case mono
    /// Upmix/downmix to two channels.
    case stereo

    /// Channel count for backends that accept a numeric channel argument.
    public var channelCount: Int? {
        switch self {
        case .preserve: nil
        case .mono: 1
        case .stereo: 2
        }
    }
}

/// Request to transcode one audio file into another.
///
/// Defaults mirror the current source-sidecar compression target: 16 kHz mono
/// AAC in an M4A container at 48 kbps.
public struct AudioTranscodeRequest: Sendable, Equatable {
    public let inputURL: URL
    public let outputURL: URL
    public let codec: AudioProcessingCodec
    public let container: AudioProcessingContainer
    public let channelMode: AudioProcessingChannelMode
    public let sampleRate: Double?
    public let bitrate: Int?

    public init(
        inputURL: URL,
        outputURL: URL,
        codec: AudioProcessingCodec = .aac,
        container: AudioProcessingContainer = .m4a,
        channelMode: AudioProcessingChannelMode = .mono,
        sampleRate: Double? = 16_000,
        bitrate: Int? = 48_000
    ) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.codec = codec
        self.container = container
        self.channelMode = channelMode
        self.sampleRate = sampleRate
        self.bitrate = bitrate
    }
}

/// Result returned by an audio-processing backend after a transcode.
public struct AudioTranscodeResult: Sendable, Equatable {
    public let outputURL: URL
    public let backendID: String
    public let outputBytes: UInt64
    public let inputBytes: UInt64?
    public let durationSeconds: Double?

    public init(
        outputURL: URL,
        backendID: String,
        outputBytes: UInt64,
        inputBytes: UInt64? = nil,
        durationSeconds: Double? = nil
    ) {
        self.outputURL = outputURL
        self.backendID = backendID
        self.outputBytes = outputBytes
        self.inputBytes = inputBytes
        self.durationSeconds = durationSeconds
    }
}

/// Availability probe result for one audio-processing backend.
public struct AudioProcessingBackendAvailability: Sendable, Equatable {
    public let backendID: String
    public let isAvailable: Bool
    public let executableURL: URL?
    public let reason: String?

    public init(
        backendID: String,
        isAvailable: Bool,
        executableURL: URL? = nil,
        reason: String? = nil
    ) {
        self.backendID = backendID
        self.isAvailable = isAvailable
        self.executableURL = executableURL
        self.reason = reason
    }

    public static func available(
        backendID: String,
        executableURL: URL? = nil
    ) -> Self {
        Self(backendID: backendID, isAvailable: true, executableURL: executableURL)
    }

    public static func unavailable(
        backendID: String,
        reason: String
    ) -> Self {
        Self(backendID: backendID, isAvailable: false, reason: reason)
    }
}

/// One backend failure captured while trying an audio-processing chain.
public struct AudioProcessingBackendFailure: Sendable, Equatable {
    public let backendID: String
    public let message: String

    public init(backendID: String, message: String) {
        self.backendID = backendID
        self.message = message
    }
}

/// Domain errors surfaced by audio-processing backends and coordinators.
public enum AudioProcessingError: LocalizedError, Sendable, Equatable {
    case backendUnavailable(AudioProcessingBackendAvailability)
    case allBackendsFailed([AudioProcessingBackendFailure])
    case unsupportedRequest(String)
    case inputMissing(URL)
    case cannotCreateExporter(backendID: String)
    case emptyOutput(URL)
    case outputReplacementFailed(outputURL: URL, message: String)
    case commandFailed(backendID: String, exitCode: Int32?, message: String?)
    case exportFailed(backendID: String, message: String)

    public var errorDescription: String? {
        switch self {
        case let .backendUnavailable(availability):
            if let reason = availability.reason, !reason.isEmpty {
                return "\(availability.backendID) audio backend is unavailable: \(reason)"
            }
            return "\(availability.backendID) audio backend is unavailable"
        case let .allBackendsFailed(failures):
            return allBackendsFailedDescription(failures)
        case let .unsupportedRequest(detail):
            return "Unsupported audio processing request: \(detail)"
        case let .inputMissing(url):
            return "Input audio file does not exist: \(url.lastPathComponent)"
        case let .cannotCreateExporter(backendID):
            return "\(backendID) cannot create an audio exporter for this request"
        case let .emptyOutput(url):
            return "Audio processing produced an empty output file: \(url.lastPathComponent)"
        case let .outputReplacementFailed(outputURL, message):
            return "Could not replace output audio file \(outputURL.lastPathComponent): \(message)"
        case let .commandFailed(backendID, exitCode, message):
            return commandFailureDescription(backendID: backendID, exitCode: exitCode, message: message)
        case let .exportFailed(backendID, message):
            return "\(backendID) audio export failed: \(message)"
        }
    }

    private func allBackendsFailedDescription(_ failures: [AudioProcessingBackendFailure]) -> String {
        guard !failures.isEmpty else { return "All audio processing backends failed" }
        let details = failures
            .map { "\($0.backendID): \($0.message)" }
            .joined(separator: "; ")
        return "All audio processing backends failed: \(details)"
    }

    private func commandFailureDescription(
        backendID: String,
        exitCode: Int32?,
        message: String?
    ) -> String {
        let prefix = if let exitCode {
            "\(backendID) audio command failed with exit code \(exitCode)"
        } else {
            "\(backendID) audio command failed"
        }
        guard let message, !message.isEmpty else { return prefix }
        return "\(prefix): \(message)"
    }
}
