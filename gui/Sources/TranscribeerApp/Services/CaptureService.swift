import AVFoundation
import CaptureCore
import Foundation
import os

private let logger = Logger(subsystem: "com.transcribeer", category: "CaptureService")

/// Thin façade over `DualAudioRecorder` + `AudioMixer` for the GUI pipeline.
enum CaptureService {
    enum Result {
        case recorded
        case noAudio
        case permissionDenied(String)
        case error(String)
    }

    private static let lock = NSLock()
    private static var stopContinuation: CheckedContinuation<Void, Never>?
    /// Set by `stop()` so an early click doesn't get lost between
    /// `recorder.start()` returning and the wait-for-stop task actually
    /// installing the continuation. Reset at the start of every `record()`.
    private static var stopRequested = false

    // MARK: - Private helpers

    private static func resolveMicDevice(uid: String) -> AudioDeviceID? {
        resolveDevice(uid: uid, kind: "Microphone", lookup: MicCapture.inputDeviceID(forUID:))
    }

    private static func resolveOutputDevice(uid: String) -> AudioDeviceID? {
        resolveDevice(uid: uid, kind: "Output device", lookup: SystemAudioCapture.outputDeviceID(forUID:))
    }

    private static func resolveDevice(
        uid: String,
        kind: String,
        lookup: (String) -> AudioDeviceID?
    ) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        if let id = lookup(uid) { return id }
        let message = "\(kind) '\(uid)' not found. Falling back to system default."
        logger.warning("\(message, privacy: .public)")
        NotificationManager.notifyError(message)
        return nil
    }

    private static let micDeniedMessage =
        "Microphone access denied. Enable Microphone in System Settings > Privacy & Security."

    private static func preflightMic() async -> Result? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? nil : .permissionDenied(micDeniedMessage)
        case .denied, .restricted:
            return .permissionDenied(micDeniedMessage)
        case .authorized:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Record to `sessionDir` (creates `audio.mic.caf`, `audio.sys.caf`,
    /// `timing.json`, and mixed `audio.m4a`).
    static func record(
        to sessionDir: URL,
        duration: Double?,
        audio: AppConfig.AudioSettings
    ) async -> Result {
        if let result = await preflightMic() { return result }

        lock.withLock {
            stopRequested = false
            stopContinuation = nil
        }

        let recorder = DualAudioRecorder(sessionDir: sessionDir)
        recorder.inputDeviceID = resolveMicDevice(uid: audio.inputDeviceUID)
        recorder.outputDeviceID = resolveOutputDevice(uid: audio.outputDeviceUID)
        recorder.echoCancellation = audio.aec

        do {
            try await recorder.start()
        } catch let error as SystemAudioCapture.CaptureError {
            return .permissionDenied(error.localizedDescription)
        } catch {
            return .error(error.localizedDescription)
        }

        let stopTask = Task {
            if let duration {
                // Poll the stop flag so a user click can end a fixed-duration
                // recording early. 100 ms granularity keeps the overhead low
                // and the latency imperceptible.
                let pollNanos: UInt64 = 100_000_000
                let totalNanos = UInt64(duration * 1_000_000_000)
                var elapsed: UInt64 = 0
                while elapsed < totalNanos {
                    if lock.withLock({ stopRequested }) { return }
                    try? await Task.sleep(nanoseconds: pollNanos)
                    elapsed += pollNanos
                }
            } else {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    // Resume immediately if stop() was already called before
                    // we got here; otherwise install the continuation.
                    let alreadyStopped = lock.withLock { () -> Bool in
                        if stopRequested { return true }
                        stopContinuation = cont
                        return false
                    }
                    if alreadyStopped { cont.resume() }
                }
            }
        }

        await stopTask.value
        let timing = await recorder.stop()

        do {
            try timing.write(to: sessionDir.appendingPathComponent("timing.json"))
        } catch {
            return .error("Failed to write timing: \(error.localizedDescription)")
        }

        let mixedURL = sessionDir.appendingPathComponent("audio.m4a")
        let mixer = AudioMixer()
        do {
            try mixer.mix(
                micURL: sessionDir.appendingPathComponent("audio.mic.caf"),
                sysURL: sessionDir.appendingPathComponent("audio.sys.caf"),
                timing: timing,
                outputURL: mixedURL
            )
        } catch {
            return .error("Mix failed: \(error.localizedDescription)")
        }

        let size = (
            try? FileManager.default.attributesOfItem(atPath: mixedURL.path)[.size]
                as? UInt64
        ) ?? 0
        return size > 0 ? .recorded : .noAudio
    }

    /// Human-readable snapshot of the devices the pipeline will use, for the
    /// session run log. Always includes the current system defaults so a later
    /// reader can tell whether "system default" in config meant what they expect.
    static func describeDevices(audio: AppConfig.AudioSettings) -> [String] {
        let inputs = AudioDevices.availableInputDevices()
        let outputs = AudioDevices.availableOutputDevices()
        return [
            "audio.input=\(selected(uid: audio.inputDeviceUID, in: inputs))"
                + " default=\(name(of: AudioDevices.defaultInputDeviceID(), in: inputs))",
            "audio.output=\(selected(uid: audio.outputDeviceUID, in: outputs))"
                + " default=\(name(of: AudioDevices.defaultOutputDeviceID(), in: outputs))",
            "audio.aec=\(audio.aec)",
        ]
    }

    private typealias DeviceInfo = (id: AudioDeviceID, name: String, uid: String)

    private static func selected(uid: String, in devices: [DeviceInfo]) -> String {
        guard !uid.isEmpty else { return "<system default>" }
        if let match = devices.first(where: { $0.uid == uid }) {
            return "\(match.name) [uid=\(uid)]"
        }
        return "<not found, falling back to system default> [uid=\(uid)]"
    }

    private static func name(of deviceID: AudioDeviceID?, in devices: [DeviceInfo]) -> String {
        guard let deviceID else { return "unknown" }
        return devices.first(where: { $0.id == deviceID })?.name ?? "unknown"
    }

    /// Signal the active recording to stop.
    static func stop() {
        lock.withLock {
            stopRequested = true
            stopContinuation?.resume()
            stopContinuation = nil
        }
    }
}
