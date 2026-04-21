import AVFoundation
import CaptureCore
import Foundation

/// Thin façade over `AudioCapture` + `AudioFileWriter` for the GUI pipeline.
enum CaptureService {
    enum Result {
        case recorded
        case noAudio
        case permissionDenied(String)  // human-readable which-permission message
        case error(String)
    }

    /// Record system audio (and optionally mic) to `url` until `stop()` is
    /// called (or `duration` seconds elapse).
    static func record(to url: URL, duration: Double?) async -> Result {
        let writer = AudioFileWriter.shared
        do {
            try writer.open(url: url)
        } catch {
            return .error("Cannot open output file: \(error.localizedDescription)")
        }

        // Explicitly request mic permission upfront if we intend to capture mic.
        // Without this, SCStream may fail with an opaque -3801 even though
        // Screen Recording IS granted, because the mic grant dialog never
        // gets triggered in the SCStream path.
        if AudioCapture.shared.captureMicrophone {
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            switch micStatus {
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                if !granted {
                    writer.close()
                    return .permissionDenied(
                        "Microphone access was denied. Grant it in " +
                        "System Settings → Privacy & Security → Microphone.",
                    )
                }
            case .denied, .restricted:
                writer.close()
                return .permissionDenied(
                    "Microphone access is denied or restricted. Enable it in " +
                    "System Settings → Privacy & Security → Microphone.",
                )
            case .authorized:
                break
            @unknown default:
                break
            }
        }

        do {
            try await AudioCapture.shared.start(writer: writer)
        } catch {
            writer.close()
            let ns = error as NSError
            let detail = "SCKit \(ns.domain)/\(ns.code): \(ns.localizedDescription)"
            let message = ns.localizedDescription.lowercased()
            // Error -3801 is the generic "not authorized" code; the
            // description usually hints at which underlying service failed
            // ("screen recording", "microphone", "tcc authorization denied",
            // etc.). Pass the detail through so the user can actually tell
            // what they need to grant.
            if ns.code == -3801 || message.contains("not authorized") || message.contains("authorization") {
                return .permissionDenied(detail)
            }
            return .error(detail)
        }

        if let duration {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            AudioCapture.shared.stop()
        } else {
            // Wait until stop() is called externally (stream delegate fires onStreamStopped).
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                AudioCapture.shared.onStreamStopped = {
                    continuation.resume()
                }
            }
        }

        writer.close()

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        return size > 0 ? .recorded : .noAudio
    }

    /// Signal the active recording to stop.
    static func stop() {
        AudioCapture.shared.stop()
    }
}
