@preconcurrency import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "com.transcribeer", category: "MicCapture")

/// Thread-safe float holder for audio level.
final class AudioLevel: @unchecked Sendable {
    private var _value: Float = 0
    private let lock = NSLock()

    var value: Float {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Simple thread-safe bool holder.
final class SyncBool: @unchecked Sendable {
    private var _value = false
    private let lock = NSLock()

    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Simple thread-safe optional string holder.
final class SyncString: @unchecked Sendable {
    private var _value: String?
    private let lock = NSLock()

    var value: String? {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// Thread-safe monotonic counter for tap-buffer debug logging.
final class TapCounter: @unchecked Sendable {
    private var _value: Int = 0
    private let lock = NSLock()

    func increment() -> Int {
        lock.withLock {
            _value += 1
            return _value
        }
    }
}

/// Captures microphone audio via AVAudioEngine and streams PCM buffers.
public final class MicCapture: @unchecked Sendable {
    public init() {}
    private var engine = AVAudioEngine()
    private var hasTapInstalled = false
    private let _audioLevel = AudioLevel()
    private let _hasCapturedFrames = SyncBool()
    private let _error = SyncString()
    private let _streamContinuation = OSAllocatedUnfairLock<
        AsyncStream<CapturedBuffer>.Continuation?
    >(uncheckedState: nil)
    private let _muted = SyncBool()

    /// Serialises every engine mutation: start, route-change rebuilds and stop.
    private let engineQueue = DispatchQueue(label: "com.transcribeer.mic-engine")
    private var requestedDeviceID: AudioDeviceID?
    private var echoCancellation = false
    private var configObserver: NSObjectProtocol?
    private var defaultInputListener: AudioPropertyListener?
    private var restartGeneration = 0
    /// What the running engine was built for, to ignore notifications that
    /// don't actually change the route.
    private var activeRoute: (device: AudioDeviceID?, sampleRate: Double)?

    private static let restartDebounce: DispatchTimeInterval = .milliseconds(300)
    private static let restartRetryDelay: DispatchTimeInterval = .seconds(1)
    /// Fast retries cover ~15 s — macOS 27 takes ~6 s to bring AirPods' mic
    /// up. After that keep trying slowly until stop, so a headset that comes
    /// back later still gets recorded.
    private static let fastRestartAttempts = 15
    private static let slowRestartRetryDelay: DispatchTimeInterval = .seconds(5)

    /// Incremented for every engine build; stamped on each buffer.
    private var generation = 0

    public var audioLevel: Float { _muted.value ? 0 : _audioLevel.value }
    public var hasCapturedFrames: Bool { _hasCapturedFrames.value }
    public var captureError: String? { _error.value }

    /// When muted, buffers are not forwarded to the stream and audio level
    /// reads as 0.
    public var isMuted: Bool {
        get { _muted.value }
        set { _muted.value = newValue }
    }

    public func bufferStream(
        deviceID: AudioDeviceID? = nil,
        echoCancellation: Bool = false
    ) -> AsyncStream<CapturedBuffer> {
        _streamContinuation.withLock { $0?.finish(); $0 = nil }
        engineQueue.sync { teardownEngine() }

        let errorHolder = _error

        return AsyncStream { continuation in
            self._streamContinuation.withLock { $0 = continuation }
            errorHolder.value = nil
            self._hasCapturedFrames.value = false
            continuation.onTermination = { _ in logger.info("Stream terminated") }

            logger.info("bufferStream deviceID=\(String(describing: deviceID), privacy: .public)")

            self.engineQueue.sync {
                self.requestedDeviceID = deviceID
                self.echoCancellation = echoCancellation
                if let error = self.startEngine(continuation: continuation) {
                    errorHolder.value = error
                    continuation.finish()
                    return
                }
                self.watchDefaultInput()
            }
        }
    }

    // MARK: - Engine lifecycle (engineQueue only)

    /// Build a fresh engine bound to the requested device, install the tap and
    /// start it. Returns a user-facing error message on failure.
    private func startEngine(continuation: AsyncStream<CapturedBuffer>.Continuation) -> String? {
        let engine = makeFreshEngine()
        let inputNode = engine.inputNode
        Self.applyVoiceProcessing(inputNode, enabled: echoCancellation)

        if let error = Self.applyInputDevice(inputNode: inputNode, deviceID: requestedDeviceID) {
            return error
        }

        // Use the node's actual output format as the tap format.
        // Synthesising a different format (e.g. forcing a hardware nominal
        // sample rate) causes AVFoundation to throw an uncatchable
        // NSException ("Failed to create tap due to format mismatch") when
        // the engine is in a VPIO or Bluetooth SCO context that reports a
        // non-standard rate such as 24 000 Hz.  Passing the node's own
        // format is always safe; `SourceTrackWriter` converts any rate to the
        // recording's file format.
        let tapFormat = inputNode.outputFormat(forBus: 0)
        logger.info(
            "tapFormat: sr=\(tapFormat.sampleRate, privacy: .public) ch=\(tapFormat.channelCount, privacy: .public)"
        )
        if let error = Self.validateTapFormat(tapFormat) {
            return error
        }

        generation += 1
        installTap(inputNode: inputNode, tapFormat: tapFormat, generation: generation, continuation: continuation)

        do {
            try engine.start()
            logger.info("Engine started, isRunning=\(engine.isRunning, privacy: .public)")
        } catch {
            let msg = "Mic failed: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            teardownEngine()
            return msg
        }

        activeRoute = (Self.currentDevice(of: inputNode), tapFormat.sampleRate)
        observeConfigurationChanges(of: engine)
        return nil
    }

    /// AVAudioEngine stops itself when the input device's format or route
    /// changes (AirPods connecting, the hands-free profile kicking in). Rebuild
    /// it so the recording keeps going instead of silently losing the mic.
    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleRestart(reason: "engine configuration change")
        }
    }

    /// With no pinned device the mic follows the system default input.
    private func watchDefaultInput() {
        defaultInputListener?.invalidate()
        defaultInputListener = nil
        guard requestedDeviceID == nil else { return }
        defaultInputListener = AudioPropertyListener(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultInputDevice,
            queue: engineQueue
        ) { [weak self] in
            self?.scheduleRestart(reason: "default input changed")
        }
    }

    /// Coalesce bursts of route notifications into one rebuild.
    private func scheduleRestart(reason: String) {
        engineQueue.async { [self] in
            restartGeneration += 1
            let generation = restartGeneration
            engineQueue.asyncAfter(deadline: .now() + Self.restartDebounce) { [self] in
                guard generation == restartGeneration else { return }
                restart(reason: reason, attempt: 1)
            }
        }
    }

    private func restart(reason: String, attempt: Int) {
        guard let continuation = _streamContinuation.withLock({ $0 }) else { return }
        if attempt == 1, engine.isRunning, routeIsUnchanged() {
            logger.debug("mic restart skipped, route unchanged reason=\(reason, privacy: .public)")
            return
        }
        logger.info("mic restart reason=\(reason, privacy: .public) attempt=\(attempt, privacy: .public)")

        if let pinned = requestedDeviceID,
           !AudioDevices.availableInputDevices().contains(where: { $0.id == pinned }) {
            logger.warning("pinned input device \(pinned, privacy: .public) is gone; using system default")
            requestedDeviceID = nil
            watchDefaultInput()
        }

        guard let error = startEngine(continuation: continuation) else { return }

        // Bluetooth headsets can take several seconds to come up; keep trying
        // rather than ending the recording.
        logger.error("mic restart failed attempt=\(attempt, privacy: .public): \(error, privacy: .public)")
        let delay = attempt < Self.fastRestartAttempts ? Self.restartRetryDelay : Self.slowRestartRetryDelay
        let generation = restartGeneration
        engineQueue.asyncAfter(deadline: .now() + delay) { [self] in
            guard generation == restartGeneration else { return }
            restart(reason: reason, attempt: attempt + 1)
        }
    }

    private func routeIsUnchanged() -> Bool {
        guard let activeRoute else { return false }
        let inputNode = engine.inputNode
        return Self.currentDevice(of: inputNode) == activeRoute.device
            && inputNode.outputFormat(forBus: 0).sampleRate == activeRoute.sampleRate
    }

    private static func currentDevice(of inputNode: AVAudioInputNode) -> AudioDeviceID? {
        guard let audioUnit = inputNode.audioUnit else { return nil }
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        return status == noErr ? deviceID : nil
    }

    private func teardownEngine() {
        activeRoute = nil
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if hasTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            hasTapInstalled = false
        }
        engine.stop()
    }

    // MARK: - bufferStream helpers (split for function_body_length)

    private static func applyVoiceProcessing(_ inputNode: AVAudioInputNode, enabled: Bool) {
        guard enabled else { return }
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            logger.info("Voice processing (AEC) enabled")
        } catch {
            logger.error("Failed to enable voice processing: \(error.localizedDescription)")
        }
    }

    /// Bind the input node to a specific AudioDeviceID or fall back to system
    /// default. Returns a user-facing error message on failure.
    private static func applyInputDevice(
        inputNode: AVAudioInputNode,
        deviceID: AudioDeviceID?
    ) -> String? {
        guard let id = deviceID else {
            logger.info("No deviceID, using system default")
            return nil
        }
        guard let inAU = inputNode.audioUnit else {
            let msg = "inputNode has no audio unit after prepare"
            logger.error("\(msg, privacy: .public)")
            return msg
        }
        var devID = id
        let status = AudioUnitSetProperty(
            inAU,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        logger.info("setInputDevice status=\(status, privacy: .public) (0=ok)")
        return nil
    }

    /// Validate that `format` is usable as a tap format.
    ///
    /// Returns a user-facing error message when the format is degenerate (zero
    /// sample rate or zero channels), so the caller can finish the stream
    /// instead of installing the tap. This converts a would-be crash
    /// (AVFoundation throws an uncatchable `NSException` for invalid formats)
    /// into a recoverable, surfaced error.
    ///
    /// - Note: Exposed as `internal` (not `private`) so it can be covered by
    ///   unit tests without `@testable` import overhead.
    static func validateTapFormat(_ format: AVAudioFormat) -> String? {
        guard format.sampleRate > 0, format.channelCount > 0 else {
            let msg = "Cannot install mic tap: invalid audio format "
                + "(sr=\(format.sampleRate) ch=\(format.channelCount)). "
                + "Try selecting a different input device in Audio Settings."
            logger.error("\(msg, privacy: .public)")
            return msg
        }
        return nil
    }

    private func installTap(
        inputNode: AVAudioInputNode,
        tapFormat: AVAudioFormat,
        generation: Int,
        continuation: AsyncStream<CapturedBuffer>.Continuation
    ) {
        let muted = _muted
        let level = _audioLevel
        let hasFrames = _hasCapturedFrames
        let counter = TapCounter()
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
            let count = counter.increment()
            hasFrames.value = true
            let rms = Self.normalizedRMS(from: buffer)
            level.value = min(rms * 25, 1.0)
            if count <= 5 || count.isMultiple(of: 100) {
                logger.debug(
                    "tap #\(count, privacy: .public): frames=\(buffer.frameLength, privacy: .public) rms=\(rms, privacy: .public) level=\(level.value, privacy: .public)"
                )
            }
            guard !muted.value else { return }
            continuation.yield(CapturedBuffer(buffer: buffer, generation: generation))
        }
        hasTapInstalled = true
    }

    /// Finish the async stream so consumers exit their for-await loop.
    /// Call this before stop() when you need a graceful drain.
    public func finishStream() {
        _streamContinuation.withLock { $0?.finish(); $0 = nil }
    }

    public func stop() {
        finishStream()
        engineQueue.sync {
            restartGeneration += 1
            defaultInputListener?.invalidate()
            defaultInputListener = nil
            teardownEngine()
            engine.reset()
        }
        _audioLevel.value = 0
        _hasCapturedFrames.value = false
    }

    private func makeFreshEngine() -> AVAudioEngine {
        teardownEngine()
        let freshEngine = AVAudioEngine()
        engine = freshEngine
        return freshEngine
    }

    private static func normalizedRMS(from buffer: AVAudioPCMBuffer) -> Float {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            let channelCount = Int(buffer.format.channelCount)
            if channelCount == 1 || buffer.format.isInterleaved {
                let totalSamples = buffer.format.isInterleaved
                    ? frameLength * channelCount
                    : frameLength
                var rms: Float = 0
                vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(totalSamples))
                return rms
            } else {
                var totalRMS: Float = 0
                for ch in 0..<channelCount {
                    var chRMS: Float = 0
                    vDSP_rmsqv(channelData[ch], 1, &chRMS, vDSP_Length(frameLength))
                    totalRMS += chRMS * chRMS
                }
                return sqrt(totalRMS / Float(channelCount))
            }
        }

        if let channelData = buffer.int16ChannelData {
            var floats = [Float](repeating: 0, count: frameLength)
            vDSP_vflt16(channelData[0], 1, &floats, 1, vDSP_Length(frameLength))
            var scale: Float = 1 / Float(Int16.max)
            vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(frameLength))
            var rms: Float = 0
            vDSP_rmsqv(floats, 1, &rms, vDSP_Length(frameLength))
            return rms
        }

        if let channelData = buffer.int32ChannelData {
            let scale: Float = 1 / Float(Int32.max)
            var floats = [Float](repeating: 0, count: frameLength)
            for i in 0..<frameLength { floats[i] = Float(channelData[0][i]) * scale }
            var rms: Float = 0
            vDSP_rmsqv(floats, 1, &rms, vDSP_Length(frameLength))
            return rms
        }

        return 0
    }

    // MARK: - Device queries

    /// Convert a CoreAudio AudioDeviceID to its stable UID string.
    public static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        AudioDevices.availableInputDevices()
            .first { $0.id == deviceID }?.uid
    }

    /// Query the nominal sample rate of a CoreAudio device directly from
    /// hardware.
    public static func deviceNominalSampleRate(
        for deviceID: AudioDeviceID
    ) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &sampleRate
        )
        return status == noErr ? sampleRate : nil
    }

    /// Resolve a stable CoreAudio UID string back to the current
    /// AudioDeviceID, if the device is connected.
    public static func inputDeviceID(forUID uid: String) -> AudioDeviceID? {
        AudioDevices.inputDeviceID(forUID: uid)
    }
}
