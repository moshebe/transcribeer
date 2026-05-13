import AVFoundation
import Foundation
import os

private let logger = Logger(subsystem: "com.transcribeer", category: "DualAudioRecorder")

/// Coordinates mic + system audio capture into two CAF sidecars.
///
/// Call `start()` to begin both streams, then `stop()` to finalize files and
/// receive timing metadata.  The mixed `audio.m4a` is produced separately by
/// `AudioMixer`.
public final class DualAudioRecorder: @unchecked Sendable {
    private let sessionDir: URL
    private let micCapture = MicCapture()
    private let sysCapture = SystemAudioCapture()

    private let stateLock = OSAllocatedUnfairLock<State>(uncheckedState: State())

    private struct State {
        var micFile: AVAudioFile?
        var sysFile: AVAudioFile?
        var micAnchor: Date?
        var sysAnchor: Date?
        var sysEndFrame: Int64 = 0
        var sysEndDate: Date?
        var sysDeclaredRate: Double = 0
    }

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?

    /// Resolved device IDs from UIDs (nil = system default).
    public var inputDeviceID: AudioDeviceID?
    public var outputDeviceID: AudioDeviceID?
    public var echoCancellation: Bool = false

    public init(sessionDir: URL) {
        self.sessionDir = sessionDir
    }

    // MARK: - Public API

    /// Start both capture streams and begin writing to CAF sidecars.
    public func start() async throws {
        let sysStreams = try await sysCapture.bufferStream(outputDeviceID: outputDeviceID)
        let micStream = micCapture.bufferStream(
            deviceID: inputDeviceID,
            echoCancellation: echoCancellation
        )

        micTask = Task { [self] in
            for await buffer in micStream {
                writeMic(buffer)
            }
        }

        sysTask = Task { [self] in
            for await buffer in sysStreams.systemAudio {
                writeSys(buffer)
            }
        }
    }

    /// Stop captures, close files, and return timing metadata.
    public func stop() async -> TimingMetadata {
        micCapture.finishStream()
        sysCapture.finishStream()

        await micTask?.value
        await sysTask?.value

        micCapture.stop()
        await sysCapture.stop()

        return stateLock.withLock { state in
            state.micFile = nil
            state.sysFile = nil

            var meta = TimingMetadata()
            if let anchor = state.micAnchor {
                meta.micStartEpoch = anchor.timeIntervalSince1970
            }
            if let anchor = state.sysAnchor {
                meta.sysStartEpoch = anchor.timeIntervalSince1970
            }
            meta.sysDeclaredSampleRate = state.sysDeclaredRate
            if let endDate = state.sysEndDate,
               let anchor = state.sysAnchor,
               state.sysEndFrame > 0 {
                meta.sysEffectiveSampleRate =
                    Double(state.sysEndFrame) / endDate.timeIntervalSince(anchor)
            }
            return meta
        }
    }

    // MARK: - Internal (exposed for testing)

    /// Append a mic PCM buffer. Public under the `Testing` SPI so
    /// integration tests in the gui package can drive the pipeline without
    /// needing Core Audio hardware; normal capture uses the async stream
    /// path started by `start()`.
    @_spi(Testing)
    public func writeMic(_ buffer: AVAudioPCMBuffer) {
        let mono = buffer.format.channelCount > 1
            ? (downmixToMono(buffer) ?? buffer)
            : buffer

        stateLock.withLock { state in
            if state.micAnchor == nil {
                state.micAnchor = Date()
                openMicFile(format: mono.format, state: &state)
            }

            guard let file = state.micFile else { return }

            do {
                try file.write(from: mono)
            } catch {
                logger.error("mic write failed: \(error.localizedDescription)")
            }
        }
    }

    /// Append a sys PCM buffer. See `writeMic` for the SPI rationale.
    @_spi(Testing)
    public func writeSys(_ buffer: AVAudioPCMBuffer) {
        stateLock.withLock { state in
            if state.sysAnchor == nil {
                state.sysAnchor = Date()
                state.sysDeclaredRate = buffer.format.sampleRate
                openSysFile(format: buffer.format, state: &state)
            }

            guard let file = state.sysFile else { return }

            state.sysEndFrame += Int64(buffer.frameLength)
            state.sysEndDate = Date()

            do {
                try file.write(from: buffer)
            } catch {
                logger.error("sys write failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private helpers

    private func openMicFile(format: AVAudioFormat, state: inout State) {
        let url = sessionDir.appendingPathComponent("audio.mic.caf")
        do {
            state.micFile = try AVAudioFile(
                forWriting: url,
                settings: cafSettings(from: format),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            logger.error("Failed to open mic CAF: \(error.localizedDescription)")
        }
    }

    private func openSysFile(format: AVAudioFormat, state: inout State) {
        let url = sessionDir.appendingPathComponent("audio.sys.caf")
        do {
            state.sysFile = try AVAudioFile(
                forWriting: url,
                settings: cafSettings(from: format),
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            logger.error("Failed to open sys CAF: \(error.localizedDescription)")
        }
    }

    private func cafSettings(from format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ]
    }

    private func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let srcData = buffer.floatChannelData,
              let dstData = mono.floatChannelData
        else {
            return nil
        }
        mono.frameLength = buffer.frameLength

        let chCount = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        let dst = dstData[0]

        for frame in 0..<frames {
            var sum: Float = 0
            for ch in 0..<chCount {
                sum += srcData[ch][frame]
            }
            dst[frame] = sum / Float(chCount)
        }

        return mono
    }
}
