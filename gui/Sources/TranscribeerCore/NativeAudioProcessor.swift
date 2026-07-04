import AVFoundation
import Foundation

/// Native macOS audio-processing backend powered by AVFoundation.
///
/// This backend provides the dependency-free fallback path for local audio
/// transcodes. It intentionally supports the app's current concrete need:
/// Core Audio-readable input, including capture CAF sidecars, to AAC-in-M4A.
public struct NativeAudioProcessor: AudioProcessingBackend {
    private static let backendIdentifier = "avfoundation"

    public let backendID = Self.backendIdentifier

    public init() {}

    public func availability() async -> AudioProcessingBackendAvailability {
        .available(backendID: backendID)
    }

    public func transcode(_ request: AudioTranscodeRequest) async throws -> AudioTranscodeResult {
        let backendID = self.backendID
        do {
            return try await Task.detached(priority: .utility) {
                try Self.transcodeSynchronously(request, backendID: backendID)
            }.value
        } catch let error as AudioProcessingError {
            throw error
        } catch {
            throw AudioProcessingError.exportFailed(
                backendID: backendID,
                message: error.localizedDescription
            )
        }
    }

    private static func transcodeSynchronously(
        _ request: AudioTranscodeRequest,
        backendID: String
    ) throws -> AudioTranscodeResult {
        try validate(request)
        guard FileManager.default.fileExists(atPath: request.inputURL.path) else {
            throw AudioProcessingError.inputMissing(request.inputURL)
        }

        let inputBytes = fileSize(request.inputURL)
        let inputFile = try AVAudioFile(forReading: request.inputURL)
        let sourceFormat = inputFile.processingFormat
        let duration = durationSeconds(file: inputFile, sourceFormat: sourceFormat)
        let targetFormat = try makeTargetFormat(
            for: request,
            sourceFormat: sourceFormat,
            backendID: backendID
        )
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw AudioProcessingError.cannotCreateExporter(backendID: backendID)
        }

        let tempURL = temporaryOutputURL(for: request.outputURL, container: request.container)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let outputFile = try makeOutputFile(at: tempURL, request: request, targetFormat: targetFormat)
        try transcode(
            inputFile: inputFile,
            converter: converter,
            targetFormat: targetFormat,
            outputFile: outputFile
        )
        guard SourceAudioFiles.isNonEmpty(tempURL) else {
            throw AudioProcessingError.emptyOutput(request.outputURL)
        }

        try replace(tempURL: tempURL, outputURL: request.outputURL)
        return AudioTranscodeResult(
            outputURL: request.outputURL,
            backendID: backendID,
            outputBytes: fileSize(request.outputURL),
            inputBytes: inputBytes,
            durationSeconds: duration
        )
    }

    private static func validate(_ request: AudioTranscodeRequest) throws {
        guard request.codec == .aac else {
            throw AudioProcessingError.unsupportedRequest("AVFoundation fallback only writes AAC audio")
        }
        guard request.container == .m4a else {
            throw AudioProcessingError.unsupportedRequest("AVFoundation fallback only writes M4A containers")
        }
        if let sampleRate = request.sampleRate, !sampleRate.isFinite || sampleRate <= 0 {
            throw AudioProcessingError.unsupportedRequest("sample rate must be positive")
        }
        if let bitrate = request.bitrate, bitrate <= 0 {
            throw AudioProcessingError.unsupportedRequest("bitrate must be positive")
        }
    }

    private static func makeTargetFormat(
        for request: AudioTranscodeRequest,
        sourceFormat: AVAudioFormat,
        backendID: String
    ) throws -> AVAudioFormat {
        let sampleRate = request.sampleRate ?? sourceFormat.sampleRate
        let channels = targetChannelCount(request.channelMode, sourceFormat: sourceFormat)
        guard channels > 0 else {
            throw AudioProcessingError.unsupportedRequest("source audio has no channels")
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw AudioProcessingError.cannotCreateExporter(backendID: backendID)
        }
        return format
    }

    private static func targetChannelCount(
        _ mode: AudioProcessingChannelMode,
        sourceFormat: AVAudioFormat
    ) -> AVAudioChannelCount {
        switch mode {
        case .preserve: sourceFormat.channelCount
        case .mono: 1
        case .stereo: 2
        }
    }

    private static func makeOutputFile(
        at url: URL,
        request: AudioTranscodeRequest,
        targetFormat: AVAudioFormat
    ) throws -> AVAudioFile {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: targetFormat.sampleRate,
            AVNumberOfChannelsKey: Int(targetFormat.channelCount),
        ]
        if let bitrate = request.bitrate {
            settings[AVEncoderBitRateKey] = bitrate
        }
        return try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    private static func transcode(
        inputFile: AVAudioFile,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat,
        outputFile: AVAudioFile
    ) throws {
        let chunkFrames = AVAudioFrameCount(max(1, Int(inputFile.processingFormat.sampleRate)))
        while inputFile.framePosition < inputFile.length {
            let remaining = inputFile.length - inputFile.framePosition
            let framesToRead = AVAudioFrameCount(min(Int64(chunkFrames), remaining))
            guard let readBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFile.processingFormat,
                frameCapacity: framesToRead
            ) else {
                throw AudioProcessingError.cannotCreateExporter(backendID: Self.backendIdentifier)
            }
            try inputFile.read(into: readBuffer, frameCount: framesToRead)
            guard readBuffer.frameLength > 0 else { break }

            let converted = try convert(
                buffer: readBuffer,
                converter: converter,
                outputFormat: targetFormat
            )
            if converted.frameLength > 0 {
                try outputFile.write(from: converted)
            }
        }
    }

    private static func convert(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputFrames = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(outputFrames, 1)
        ) else {
            throw AudioProcessingError.cannotCreateExporter(backendID: Self.backendIdentifier)
        }

        converter.reset()
        var didProvideInput = false
        var convertError: NSError?
        let status = converter.convert(to: outputBuffer, error: &convertError) { _, statusOut in
            if didProvideInput {
                statusOut.pointee = .endOfStream
                return nil
            }
            didProvideInput = true
            statusOut.pointee = .haveData
            return buffer
        }
        if let convertError {
            throw AudioProcessingError.exportFailed(
                backendID: Self.backendIdentifier,
                message: convertError.localizedDescription
            )
        }
        guard status != .error else {
            throw AudioProcessingError.exportFailed(
                backendID: Self.backendIdentifier,
                message: "audio conversion failed"
            )
        }
        return outputBuffer
    }

    private static func durationSeconds(file: AVAudioFile, sourceFormat: AVAudioFormat) -> Double? {
        guard sourceFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / sourceFormat.sampleRate
    }

    private static func temporaryOutputURL(for outputURL: URL, container: AudioProcessingContainer) -> URL {
        outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).\(UUID().uuidString)")
            .appendingPathExtension(container.fileExtension)
    }

    private static func replace(tempURL: URL, outputURL: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    outputURL,
                    withItemAt: tempURL,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try FileManager.default.moveItem(at: tempURL, to: outputURL)
            }
        } catch {
            throw AudioProcessingError.outputReplacementFailed(
                outputURL: outputURL,
                message: error.localizedDescription
            )
        }
    }

    private static func fileSize(_ url: URL) -> UInt64 {
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
