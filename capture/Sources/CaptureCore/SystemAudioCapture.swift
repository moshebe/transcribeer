@preconcurrency import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import Dispatch
import Foundation
import os

private let logger = Logger(subsystem: "com.transcribeer", category: "SystemAudioCapture")

/// Captures system output audio via a Core Audio process tap.
public final class SystemAudioCapture: @unchecked Sendable {
    public init() {}
    private let _audioLevel = AudioLevel()

    /// Thread-safe audio level (0…1) from the system audio stream.
    public var audioLevel: Float { _audioLevel.value }

    private let _aggregateDeviceID = OSAllocatedUnfairLock<AudioObjectID>(
        uncheckedState: AudioObjectID(kAudioObjectUnknown)
    )
    private let _tapID = OSAllocatedUnfairLock<AudioObjectID>(
        uncheckedState: AudioObjectID(kAudioObjectUnknown)
    )
    private let _ioProcID = OSAllocatedUnfairLock<AudioDeviceIOProcID?>(
        uncheckedState: nil
    )
    private let _sysContinuation = OSAllocatedUnfairLock<
        AsyncStream<AVAudioPCMBuffer>.Continuation?
    >(uncheckedState: nil)
    private let callbackQueue = DispatchQueue(
        label: "com.transcribeer.system-audio",
        qos: .userInteractive
    )

    /// Serialises tap creation, route-change rebuilds and teardown.
    private let controlQueue = DispatchQueue(label: "com.transcribeer.system-audio-control")
    private var requestedOutputDeviceID: AudioDeviceID?
    private var routeListeners: [AudioPropertyListener] = []
    /// What the running tap was built for, to ignore notifications that
    /// don't actually change the route.
    private var activeRoute: (device: AudioDeviceID, sampleRate: Double)?
    private var restartGeneration = 0

    private static let restartDebounce: DispatchTimeInterval = .milliseconds(300)
    private static let restartRetryDelay: DispatchTimeInterval = .seconds(1)
    private static let maxRestartAttempts = 15

    /// Called (on an internal queue) right before the tap is rebuilt after a
    /// route change, so the writer can account for the gap.
    public var onReconfigure: (@Sendable () -> Void)?

    public struct CaptureStreams {
        public let systemAudio: AsyncStream<AVAudioPCMBuffer>
    }

    public func bufferStream(
        outputDeviceID: AudioDeviceID? = nil
    ) async throws -> CaptureStreams {
        await stop()

        let sysStream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self._sysContinuation.withLock { $0 = continuation }
        }

        try controlQueue.sync {
            requestedOutputDeviceID = outputDeviceID
            do {
                try startTap()
            } catch {
                _sysContinuation.withLock { $0?.finish(); $0 = nil }
                throw error
            }
        }
        return CaptureStreams(systemAudio: sysStream)
    }

    // MARK: - Tap lifecycle (controlQueue only)

    /// Create the process tap + aggregate device on the current output device
    /// and start the IO proc. Cleans up after itself on failure.
    private func startTap() throws {
        let outputDevice = try resolveOutputDevice(requested: requestedOutputDeviceID)
        let outputUID = try Self.deviceUID(for: outputDevice)
        let tap = try createProcessTap(outputUID: outputUID)
        let tapID = tap.id
        let aggregateDeviceID: AudioObjectID
        do {
            aggregateDeviceID = try createAggregateDevice(
                outputUID: outputUID,
                tapUUID: tap.uuid
            )
        } catch {
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw error
        }

        let format: AVAudioFormat
        let ioProcID: AudioDeviceIOProcID
        do {
            format = try resolveTapFormat(tapID: tapID)
            ioProcID = try registerIOProc(aggregateDeviceID: aggregateDeviceID, format: format)
        } catch {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw error
        }

        let startStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard startStatus == noErr else {
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.startFailed(startStatus)
        }

        _tapID.withLock { $0 = tapID }
        _aggregateDeviceID.withLock { $0 = aggregateDeviceID }
        _ioProcID.withLock { $0 = ioProcID }
        activeRoute = (outputDevice, format.sampleRate)
        logger.info(
            """
            tap started device=\(outputDevice, privacy: .public) \
            sr=\(format.sampleRate, privacy: .public)
            """
        )
        watchRoute(outputDevice: outputDevice, tapID: tapID)
    }

    // MARK: - bufferStream helpers (split for function_body_length)

    /// Resolve the output device, preferring the requested one and falling
    /// back to the system default when it is gone.
    private func resolveOutputDevice(requested: AudioDeviceID?) throws -> AudioDeviceID {
        if let requested, (try? Self.deviceUID(for: requested)) != nil {
            return requested
        }
        return try Self.defaultOutputDeviceID()
    }

    private func createProcessTap(outputUID: String) throws -> (id: AudioObjectID, uuid: UUID) {
        let tapUUID = UUID()
        let tapDescription = CATapDescription()
        tapDescription.name = "Transcribeer System Audio"
        tapDescription.uuid = tapUUID
        // `processes = [currentPID]` + `isExclusive = true` tells Core Audio
        // to tap *everything* playing to the device EXCEPT our own process,
        // so our notification sounds don't bleed into the recording.
        tapDescription.processes = Self.currentProcessObjectID().map { [$0] } ?? []
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        tapDescription.isMixdown = true
        tapDescription.isMono = true
        tapDescription.isExclusive = true
        tapDescription.deviceUID = outputUID
        tapDescription.stream = 0

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr else {
            throw CaptureError.tapCreationFailed(status)
        }
        return (tapID, tapUUID)
    }

    private func createAggregateDevice(
        outputUID: String,
        tapUUID: UUID
    ) throws -> AudioObjectID {
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Transcribeer System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceInputChannelsKey: [],
                ],
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                ],
            ],
        ]
        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary,
            &aggregateDeviceID
        )
        guard status == noErr else {
            throw CaptureError.aggregateDeviceCreationFailed(status)
        }
        return aggregateDeviceID
    }

    private func resolveTapFormat(tapID: AudioObjectID) throws -> AVAudioFormat {
        var streamDescription = try Self.tapStreamDescription(for: tapID)
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CaptureError.invalidTapFormat
        }
        return format
    }

    private func registerIOProc(
        aggregateDeviceID: AudioObjectID,
        format: AVAudioFormat
    ) throws -> AudioDeviceIOProcID {
        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregateDeviceID,
            callbackQueue
        ) { [weak self] _, inInputData, _, _, _ in
            self?.handleInputData(inInputData, format: format)
        }
        guard status == noErr, let ioProcID else {
            throw CaptureError.ioProcCreationFailed(status)
        }
        return ioProcID
    }

    /// Finish the async stream so consumers exit their for-await loop.
    /// Call this before stop() when you need a graceful drain.
    public func finishStream() {
        _sysContinuation.withLock { $0?.finish(); $0 = nil }
    }

    public func stop() async {
        finishStream()
        _audioLevel.value = 0
        controlQueue.sync {
            restartGeneration += 1
            routeListeners.forEach { $0.invalidate() }
            routeListeners = []
            teardownTap()
        }
    }

    private func teardownTap() {
        activeRoute = nil
        let aggregateDeviceID = _aggregateDeviceID.withLock { state -> AudioObjectID in
            let current = state
            state = AudioObjectID(kAudioObjectUnknown)
            return current
        }
        let ioProcID = _ioProcID.withLock { state -> AudioDeviceIOProcID? in
            let current = state
            state = nil
            return current
        }
        let tapID = _tapID.withLock { state -> AudioObjectID in
            let current = state
            state = AudioObjectID(kAudioObjectUnknown)
            return current
        }

        if aggregateDeviceID != AudioObjectID(kAudioObjectUnknown) {
            if let ioProcID {
                _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }

        if tapID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(tapID)
        }
    }

    private func handleInputData(
        _ inputData: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let streamDescription = format.streamDescription
        let bytesPerFrame = Int(streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, let firstBuffer = sourceBuffers.first else { return }

        let frameCount = AVAudioFrameCount(
            Int(firstBuffer.mDataByteSize) / bytesPerFrame
        )
        guard frameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        pcmBuffer.frameLength = frameCount

        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            pcmBuffer.mutableAudioBufferList
        )
        guard destinationBuffers.count == sourceBuffers.count else { return }

        for index in 0..<sourceBuffers.count {
            let source = sourceBuffers[index]
            let copySize = min(
                Int(source.mDataByteSize),
                Int(destinationBuffers[index].mDataByteSize)
            )
            guard copySize > 0,
                  let sourceData = source.mData,
                  let destinationData = destinationBuffers[index].mData
            else {
                continue
            }

            memcpy(destinationData, sourceData, copySize)
            destinationBuffers[index].mDataByteSize = UInt32(copySize)
        }

        if let channelData = pcmBuffer.floatChannelData, pcmBuffer.frameLength > 0 {
            var rms: Float = 0
            vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(pcmBuffer.frameLength))
            _audioLevel.value = min(rms * 25, 1.0)
        }

        _ = _sysContinuation.withLock { $0?.yield(pcmBuffer) }
    }

    // MARK: - Static helpers

    private static func propertyAddress(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    private static func currentProcessObjectID() -> AudioObjectID? {
        var pid = getpid()
        var address = propertyAddress(
            selector: kAudioHardwarePropertyTranslatePIDToProcessObject
        )
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        let status = withUnsafePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &dataSize,
                &processObjectID
            )
        }

        guard status == noErr,
              processObjectID != AudioObjectID(kAudioObjectUnknown)
        else {
            return nil
        }
        return processObjectID
    }

    public static func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = propertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw CaptureError.noOutputDevice
        }
        return deviceID
    }

    /// Resolve a stable CoreAudio UID string back to the current
    /// AudioDeviceID, if the device is connected.
    public static func outputDeviceID(forUID uid: String) -> AudioDeviceID? {
        AudioDevices.outputDeviceID(forUID: uid)
    }

    private static func deviceUID(for deviceID: AudioDeviceID) throws -> String {
        var address = propertyAddress(selector: kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &uid
        )

        guard status == noErr, let uid else {
            throw CaptureError.outputDeviceUIDUnavailable(status)
        }
        return uid.takeUnretainedValue() as String
    }

    private static func tapStreamDescription(
        for tapID: AudioObjectID
    ) throws -> AudioStreamBasicDescription {
        var address = propertyAddress(selector: kAudioTapPropertyFormat)
        var streamDescription = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = AudioObjectGetPropertyData(
            tapID,
            &address,
            0,
            nil,
            &dataSize,
            &streamDescription
        )

        guard status == noErr else {
            throw CaptureError.tapFormatUnavailable(status)
        }
        return streamDescription
    }

    public enum CaptureError: LocalizedError {
        case noOutputDevice
        case outputDeviceUIDUnavailable(OSStatus)
        case tapCreationFailed(OSStatus)
        case aggregateDeviceCreationFailed(OSStatus)
        case tapFormatUnavailable(OSStatus)
        case invalidTapFormat
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .noOutputDevice:
                "No audio output device is currently available."
            case .outputDeviceUIDUnavailable(let status):
                "Unable to inspect the system output device (OSStatus \(status))."
            case .tapCreationFailed(let status):
                "System audio capture could not start. Enable System Audio Recording "
                    + "in System Settings > Privacy & Security (OSStatus \(status))."
            case .aggregateDeviceCreationFailed(let status):
                "Unable to create the Core Audio aggregate device (OSStatus \(status))."
            case .tapFormatUnavailable(let status):
                "Unable to inspect the system audio tap format (OSStatus \(status))."
            case .invalidTapFormat:
                "System audio capture produced an unsupported audio format."
            case .ioProcCreationFailed(let status):
                "Unable to create the system audio IO callback (OSStatus \(status))."
            case .startFailed(let status):
                "Unable to start system audio capture (OSStatus \(status))."
            }
        }
    }
}

// MARK: - Route changes

extension SystemAudioCapture {
    /// The tap is bound to one output device, so a route change (AirPods
    /// connecting, the hands-free profile changing the sample rate, the device
    /// disappearing) would otherwise leave us recording silence or audio with
    /// the wrong rate. Any of these rebuilds the tap.
    private func watchRoute(outputDevice: AudioDeviceID, tapID: AudioObjectID) {
        routeListeners.forEach { $0.invalidate() }
        var listeners: [AudioPropertyListener?] = [
            AudioPropertyListener(
                objectID: tapID, selector: kAudioTapPropertyFormat, queue: controlQueue
            ) { [weak self] in self?.scheduleRestart(reason: "tap format changed") },
            AudioPropertyListener(
                objectID: outputDevice, selector: kAudioDevicePropertyDeviceIsAlive, queue: controlQueue
            ) { [weak self] in self?.scheduleRestart(reason: "output device gone") },
        ]
        if requestedOutputDeviceID == nil {
            listeners.append(AudioPropertyListener(
                objectID: AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyDefaultOutputDevice,
                queue: controlQueue
            ) { [weak self] in self?.scheduleRestart(reason: "default output changed") })
        }
        routeListeners = listeners.compactMap(\.self)
    }

    /// Coalesce bursts of route notifications into one rebuild.
    private func scheduleRestart(reason: String) {
        controlQueue.async { [self] in
            restartGeneration += 1
            let generation = restartGeneration
            controlQueue.asyncAfter(deadline: .now() + Self.restartDebounce) { [self] in
                guard generation == restartGeneration else { return }
                restart(reason: reason, attempt: 1)
            }
        }
    }

    private func restart(reason: String, attempt: Int) {
        guard _sysContinuation.withLock({ $0 != nil }) else { return }
        if attempt == 1, routeIsUnchanged() {
            logger.debug("tap restart skipped, route unchanged reason=\(reason, privacy: .public)")
            return
        }
        logger.info("tap restart reason=\(reason, privacy: .public) attempt=\(attempt, privacy: .public)")
        teardownTap()
        onReconfigure?()
        do {
            try startTap()
        } catch {
            guard attempt < Self.maxRestartAttempts else {
                logger.error("tap restart gave up: \(error.localizedDescription, privacy: .public)")
                return
            }
            let generation = restartGeneration
            controlQueue.asyncAfter(deadline: .now() + Self.restartRetryDelay) { [self] in
                guard generation == restartGeneration else { return }
                restart(reason: reason, attempt: attempt + 1)
            }
        }
    }

    private func routeIsUnchanged() -> Bool {
        guard let activeRoute,
              let device = try? resolveOutputDevice(requested: requestedOutputDeviceID),
              device == activeRoute.device
        else { return false }
        let tapID = _tapID.withLock { $0 }
        guard tapID != AudioObjectID(kAudioObjectUnknown),
              let format = try? Self.tapStreamDescription(for: tapID)
        else { return false }
        return format.mSampleRate == activeRoute.sampleRate
    }
}
