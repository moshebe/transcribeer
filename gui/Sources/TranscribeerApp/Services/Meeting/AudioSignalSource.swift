import CoreAudio
import Foundation

// MARK: - Audio Signal Source Protocol

/// Observes microphone activation status changes across physical input devices.
///
/// Does NOT capture audio — only reads the `kAudioDevicePropertyDeviceIsRunningSomewhere`
/// flag on each input device, which flips when any process opens the mic.
protocol AudioSignalSource: Sendable {
    /// Emits `true` when any physical input device becomes active, `false` when all go silent.
    var signals: AsyncStream<Bool> { get }
    /// Synchronous read of current hardware state.
    var isActive: Bool { get }
}

// MARK: - CoreAudio HAL Signal Source

/// Monitors `kAudioDevicePropertyDeviceIsRunningSomewhere` on all physical input devices.
/// Does NOT capture audio — only reads activation status, so it does not require mic TCC.
final class CoreAudioSignalSource: AudioSignalSource, @unchecked Sendable {
    private let listenerQueue = DispatchQueue(label: "com.transcribeer.mic-listener")
    private var deviceIDs: [AudioDeviceID] = []
    private var continuation: AsyncStream<Bool>.Continuation?
    private var lastEmittedValue = false

    let signals: AsyncStream<Bool>

    var isActive: Bool {
        listenerQueue.sync {
            deviceIDs.contains { Self.isDeviceRunning($0) }
        }
    }

    init() {
        let (stream, capturedContinuation) = AsyncStream.makeStream(of: Bool.self)
        self.signals = stream

        // Install listeners inside listenerQueue.sync to prevent data races
        // between property initialization and the first callback.
        listenerQueue.sync {
            self.continuation = capturedContinuation
            self.deviceIDs = Self.physicalInputDeviceIDs()

            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            for deviceID in self.deviceIDs {
                var address = Self.deviceRunningAddress()
                AudioObjectAddPropertyListener(deviceID, &address, Self.listenerCallback, selfPtr)
            }
        }
    }

    deinit {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        for deviceID in deviceIDs {
            var address = Self.deviceRunningAddress()
            AudioObjectRemovePropertyListener(deviceID, &address, Self.listenerCallback, selfPtr)
        }
        continuation?.finish()
    }

    // MARK: - Listener Callback

    private static let listenerCallback: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        guard let clientData else { return kAudioHardwareNoError }
        let source = Unmanaged<CoreAudioSignalSource>.fromOpaque(clientData).takeUnretainedValue()
        source.checkAndEmit()
        return kAudioHardwareNoError
    }

    private func checkAndEmit() {
        listenerQueue.async { [weak self] in
            guard let self else { return }
            let anyRunning = self.deviceIDs.contains { Self.isDeviceRunning($0) }
            if anyRunning != self.lastEmittedValue {
                self.lastEmittedValue = anyRunning
                self.continuation?.yield(anyRunning)
            }
        }
    }

    // MARK: - Helpers

    private static func deviceRunningAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
    }

    private static func physicalInputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize,
        ) == kAudioHardwareNoError else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs,
        ) == kAudioHardwareNoError else { return [] }

        return deviceIDs.filter(hasInputStreams)
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain,
        )
        var inputSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &inputSize)
        return status == kAudioHardwareNoError && inputSize > 0
    }

    private static func isDeviceRunning(_ deviceID: AudioDeviceID) -> Bool {
        var address = deviceRunningAddress()
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &isRunning)
        return status == kAudioHardwareNoError && isRunning != 0
    }
}
