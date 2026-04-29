import Foundation
import Testing
@testable import TranscribeerCore

/// Tests for `AudioValidation.hasAudibleSignal` and the `ensureAudibleSignal`
/// throw-helper that fires before WhisperKit is loaded.
struct AudioValidationTests {
    // MARK: - Synthetic WAV helper

    /// Build a 16-bit PCM mono WAV at 16 kHz with a 220 Hz sine wave of the
    /// given peak amplitude. `amplitude == 0` yields pure silence.
    private static func makeWAV(
        amplitude: Float,
        durationSec: Double = 5.0,
        sampleRate: UInt32 = 16000
    ) -> Data {
        let sampleCount = Int(durationSec * Double(sampleRate))
        var pcm = Data(count: sampleCount * 2)
        if amplitude > 0 {
            let peakInt = Float(Int16.max)
            pcm.withUnsafeMutableBytes { buf in
                guard let ptr = buf.bindMemory(to: Int16.self).baseAddress else { return }
                for i in 0..<sampleCount {
                    let t = Float(i) / Float(sampleRate)
                    let v = amplitude * peakInt * sinf(2 * .pi * 220 * t)
                    ptr[i] = Int16(v.rounded())
                }
            }
        }

        var h = Data(count: 44)
        func w32(_ off: Int, _ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { h.replaceSubrange(off..<(off + 4), with: $0) }
        }
        func w16(_ off: Int, _ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { h.replaceSubrange(off..<(off + 2), with: $0) }
        }
        h[0...3]   = Data([0x52, 0x49, 0x46, 0x46]) // RIFF
        w32(4, 36 + UInt32(pcm.count))
        h[8...11]  = Data([0x57, 0x41, 0x56, 0x45]) // WAVE
        h[12...15] = Data([0x66, 0x6d, 0x74, 0x20]) // fmt
        w32(16, 16)
        w16(20, 1)                // PCM
        w16(22, 1)                // mono
        w32(24, sampleRate)
        w32(28, sampleRate * 2)   // ByteRate
        w16(32, 2)                // BlockAlign
        w16(34, 16)               // BitsPerSample
        h[36...39] = Data([0x64, 0x61, 0x74, 0x61]) // data
        w32(40, UInt32(pcm.count))
        return h + pcm
    }

    private static func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-validation-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    // MARK: - Peak-amplitude threshold cases
    //
    // Table-driven so the boundary around the 0.001 (~-60 dBFS) threshold is
    // visible in one place. The whispered case (0.002) is the critical one:
    // a more aggressive threshold (e.g. 0.005) would false-positive reject
    // whispered dialogue.

    @Test(
        "Peak-amplitude threshold at ~-60 dBFS",
        arguments: [
            (amplitude: Float(0.0), expected: false, label: "pure silence / zero samples"),
            (amplitude: Float(0.3), expected: true, label: "normal speech ≈ -10 dBFS"),
            (amplitude: Float(0.01), expected: true, label: "distant-mic speech ≈ -40 dBFS"),
            (amplitude: Float(0.002), expected: true, label: "whispered ≈ -54 dBFS"),
            (amplitude: Float(0.0005), expected: false, label: "dither-level ≈ -66 dBFS"),
        ]
    )
    func peakThreshold(amplitude: Float, expected: Bool, label: String) throws {
        let url = try Self.writeTemp(Self.makeWAV(amplitude: amplitude))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AudioValidation.hasAudibleSignal(at: url) == expected, "\(label)")
    }

    // MARK: - Fallback behavior

    @Test("Unreadable files conservatively return true so the real decoder can surface the format error")
    func unreadableFileFallsBackToTrue() throws {
        let url = try Self.writeTemp(Data(repeating: 0x7f, count: 10))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AudioValidation.hasAudibleSignal(at: url) == true)
    }

    // MARK: - ensureAudibleSignal throw-helper

    @Test("ensureAudibleSignal throws .silent on a pure-zeros file")
    func ensureThrowsOnSilent() throws {
        let url = try Self.writeTemp(Self.makeWAV(amplitude: 0))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: AudioValidationError.self) {
            try AudioValidation.ensureAudibleSignal(at: url)
        }
    }

    @Test("ensureAudibleSignal returns normally for audible recordings")
    func ensurePassesOnAudible() throws {
        let url = try Self.writeTemp(Self.makeWAV(amplitude: 0.3))
        defer { try? FileManager.default.removeItem(at: url) }
        // Should not throw.
        try AudioValidation.ensureAudibleSignal(at: url)
    }

    // MARK: - AudioValidationError

    @Test("errorDescription mentions the filename and reflects the actual probe window")
    func errorDescriptionReflectsInputs() {
        let url = URL(fileURLWithPath: "/tmp/meeting.m4a")
        let err = AudioValidationError.silent(url: url, probeSeconds: 45)
        let message = err.errorDescription ?? ""
        #expect(message.contains("meeting.m4a"))
        #expect(message.contains("silent"))
        #expect(message.contains("45 seconds"))
    }
}
