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

    private let stateLock: OSAllocatedUnfairLock<State>

    private struct State {
        var mic: SourceTrackWriter
        var sys: SourceTrackWriter
    }

    private var micTask: Task<Void, Never>?
    private var sysTask: Task<Void, Never>?

    /// Resolved device IDs from UIDs (nil = system default).
    public var inputDeviceID: AudioDeviceID?
    public var outputDeviceID: AudioDeviceID?
    public var echoCancellation: Bool = false

    public init(sessionDir: URL) {
        self.sessionDir = sessionDir
        stateLock = OSAllocatedUnfairLock(uncheckedState: State(
            mic: SourceTrackWriter(url: sessionDir.appendingPathComponent("audio.mic.caf")),
            sys: SourceTrackWriter(url: sessionDir.appendingPathComponent("audio.sys.caf"))
        ))
    }

    // MARK: - Public API

    /// Thrown by `start()` when the microphone tap cannot be installed.
    public struct MicCaptureError: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Start both capture streams and begin writing to CAF sidecars.
    ///
    /// Throws `MicCaptureError` when the microphone tap fails immediately
    /// (e.g. format mismatch due to a VPIO/Bluetooth SCO context).  The error
    /// message is user-facing and safe to display directly in an alert.
    public func start() async throws {
        // A rebuilt capture (audio route change) leaves a hole in its stream;
        // the writer fills it with silence so mic and system audio stay aligned.
        micCapture.onReconfigure = { [weak self] in
            self?.stateLock.withLock { $0.mic.markDiscontinuity() }
        }
        sysCapture.onReconfigure = { [weak self] in
            self?.stateLock.withLock { $0.sys.markDiscontinuity() }
        }
        let sysStreams = try await sysCapture.bufferStream(outputDeviceID: outputDeviceID)
        let micStream = micCapture.bufferStream(
            deviceID: inputDeviceID,
            echoCancellation: echoCancellation
        )

        // `bufferStream` sets `captureError` synchronously and finishes the
        // stream before returning when the tap format is invalid.  Yield once
        // so the AsyncStream machinery can flush the finish signal, then check.
        await Task.yield()
        if let err = micCapture.captureError {
            logger.error("Mic tap failed at start: \(err, privacy: .public)")
            throw MicCaptureError(err)
        }

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
            state.mic.close()
            state.sys.close()

            var meta = TimingMetadata()
            meta.micStartEpoch = state.mic.anchor?.timeIntervalSince1970
            meta.sysStartEpoch = state.sys.anchor?.timeIntervalSince1970
            meta.sysDeclaredSampleRate = state.sys.fileSampleRate
            // Under a second of wall clock is too short to measure a rate;
            // 0 tells `AudioMixer` to trust the declared one.
            if let endDate = state.sys.lastWriteDate,
               let anchor = state.sys.anchor,
               state.sys.framesWritten > 0,
               endDate.timeIntervalSince(anchor) >= 1 {
                meta.sysEffectiveSampleRate =
                    Double(state.sys.framesWritten) / endDate.timeIntervalSince(anchor)
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
    public func writeMic(_ buffer: AVAudioPCMBuffer, at date: Date = Date()) {
        stateLock.withLock { $0.mic.write(buffer, at: date) }
    }

    /// Append a sys PCM buffer. See `writeMic` for the SPI rationale.
    @_spi(Testing)
    public func writeSys(_ buffer: AVAudioPCMBuffer, at date: Date = Date()) {
        stateLock.withLock { $0.sys.write(buffer, at: date) }
    }

    /// Simulate a capture rebuild for tests (normally driven by
    /// `onReconfigure` from the captures).
    @_spi(Testing)
    public func markDiscontinuity(mic: Bool, sys: Bool) {
        stateLock.withLock { state in
            if mic { state.mic.markDiscontinuity() }
            if sys { state.sys.markDiscontinuity() }
        }
    }
}
