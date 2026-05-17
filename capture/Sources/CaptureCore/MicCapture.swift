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
        AsyncStream<AVAudioPCMBuffer>.Continuation?
    >(uncheckedState: nil)
    private let _muted = SyncBool()

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
    ) -> AsyncStream<AVAudioPCMBuffer> {
        _streamContinuation.withLock { $0?.finish(); $0 = nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        let errorHolder = _error

        return AsyncStream { continuation in
            self._streamContinuation.withLock { $0 = continuation }
            errorHolder.value = nil
            self._hasCapturedFrames.value = false

            logger.info("bufferStream deviceID=\(String(describing: deviceID), privacy: .public)")

            let engine = self.makeFreshEngine()
            let inputNode = engine.inputNode
            Self.applyVoiceProcessing(inputNode, enabled: echoCancellation)

            guard let resolvedDeviceID = Self.applyInputDevice(
                inputNode: inputNode,
                deviceID: deviceID,
                errorHolder: errorHolder,
                continuation: continuation
            ) else { return }

            let format = inputNode.outputFormat(forBus: 0)
            let sampleRate = Self.resolveSampleRate(format: format, deviceID: resolvedDeviceID)

            guard sampleRate > 0 && format.channelCount > 0 else {
                let msg = "Invalid audio format: sr=\(sampleRate) ch=\(format.channelCount)"
                logger.error("\(msg, privacy: .public)")
                errorHolder.value = msg
                continuation.finish()
                return
            }

            let tapFormat = Self.pickTapFormat(nodeFormat: format, preferredRate: sampleRate)
            logger.info(
                "tapFormat: sr=\(tapFormat.sampleRate, privacy: .public) ch=\(tapFormat.channelCount, privacy: .public)"
            )

            self.installTap(inputNode: inputNode, tapFormat: tapFormat, continuation: continuation)

            continuation.onTermination = { _ in logger.info("Stream terminated") }

            do {
                try engine.start()
                logger.info("Engine started, isRunning=\(engine.isRunning, privacy: .public)")
            } catch {
                let msg = "Mic failed: \(error.localizedDescription)"
                logger.error("\(msg, privacy: .public)")
                errorHolder.value = msg
                self.hasTapInstalled = false
                continuation.finish()
            }
        }
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
    /// default. Returns the resolved device ID wrapped so the caller can
    /// distinguish binding failure (nil) from "use default" (.some(nil)).
    private static func applyInputDevice(
        inputNode: AVAudioInputNode,
        deviceID: AudioDeviceID?,
        errorHolder: SyncString,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
    ) -> AudioDeviceID?? {
        guard let id = deviceID else {
            logger.info("No deviceID, using system default")
            return .some(Self.defaultInputDeviceID())
        }
        guard let inAU = inputNode.audioUnit else {
            let msg = "inputNode has no audio unit after prepare"
            logger.error("\(msg, privacy: .public)")
            errorHolder.value = msg
            continuation.finish()
            return nil
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
        return .some(id)
    }

    /// Prefer the hardware-reported nominal rate over the AVAudioEngine's
    /// inputNode format, which can lag behind a device switch (e.g. swapping
    /// to a 48 kHz USB mic while the node still reports 44.1 kHz).
    private static func resolveSampleRate(
        format: AVAudioFormat,
        deviceID: AudioDeviceID?
    ) -> Double {
        let declared = format.sampleRate
        guard let devID = deviceID,
              let hwRate = Self.deviceNominalSampleRate(for: devID),
              hwRate > 0, hwRate != declared else { return declared }
        logger.info(
            "Hardware sr=\(hwRate, privacy: .public) differs from inputNode sr=\(declared, privacy: .public), using hardware rate"
        )
        return hwRate
    }

    /// Some devices report formats that don't round-trip through
    /// `AVAudioFormat(standardFormatWithSampleRate:)`; fall back through the
    /// node rate and native format so capture always gets a tap.
    private static func pickTapFormat(
        nodeFormat: AVAudioFormat,
        preferredRate: Double
    ) -> AVAudioFormat {
        if let fmt = AVAudioFormat(
            standardFormatWithSampleRate: preferredRate,
            channels: nodeFormat.channelCount
        ) {
            return fmt
        }
        if preferredRate != nodeFormat.sampleRate,
           let fmt = AVAudioFormat(
               standardFormatWithSampleRate: nodeFormat.sampleRate,
               channels: nodeFormat.channelCount
           ) {
            logger.info(
                "Hardware-rate format failed, using node rate \(nodeFormat.sampleRate, privacy: .public)"
            )
            return fmt
        }
        logger.info("Standard formats failed, using native input format")
        return nodeFormat
    }

    private func installTap(
        inputNode: AVAudioInputNode,
        tapFormat: AVAudioFormat,
        continuation: AsyncStream<AVAudioPCMBuffer>.Continuation
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
            continuation.yield(buffer)
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
        if hasTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            hasTapInstalled = false
        }
        engine.stop()
        engine.reset()
        _audioLevel.value = 0
        _hasCapturedFrames.value = false
    }

    private func makeFreshEngine() -> AVAudioEngine {
        if hasTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            hasTapInstalled = false
        }
        engine.stop()
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

    /// List available input devices.
    public static func availableInputDevices() -> [(id: AudioDeviceID, name: String)] {
        AudioDevices.availableInputDevices().map { (id: $0.id, name: $0.name) }
    }

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

    public static func defaultInputDeviceID() -> AudioDeviceID? {
        AudioDevices.defaultInputDeviceID()
    }
}
