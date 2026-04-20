import XCTest
@testable import TranscribeerCore

/// Tests for `AudioValidation.hasAudibleSignal` — the up-front silent-recording
/// guard that fires before WhisperKit is loaded.
final class AudioValidationTests: XCTestCase {
    // MARK: - Synthetic WAV helper

    /// Build a 16-bit PCM mono WAV at 16 kHz with a 220 Hz sine wave of the
    /// given peak amplitude. `amplitude == 0` yields pure silence.
    private func makeWAV(
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

    private func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-validation-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    // MARK: - Peak-amplitude threshold cases

    func testDetectsSilentFile() throws {
        let url = try writeTemp(makeWAV(amplitude: 0))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(try AudioValidation.hasAudibleSignal(at: url))
    }

    func testAcceptsNormalSpeechAmplitude() throws {
        // 0.3 ≈ -10 dBFS — well above any plausible noise floor
        let url = try writeTemp(makeWAV(amplitude: 0.3))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try AudioValidation.hasAudibleSignal(at: url))
    }

    func testAcceptsQuietSpeech() throws {
        // 0.01 ≈ -40 dBFS — distant-mic speech
        let url = try writeTemp(makeWAV(amplitude: 0.01))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try AudioValidation.hasAudibleSignal(at: url))
    }

    func testAcceptsWhisperedSpeech() throws {
        // 0.002 ≈ -54 dBFS — whispered into a close mic. This is exactly the
        // case a more aggressive threshold (e.g. 0.005) would have false-
        // positive rejected.
        let url = try writeTemp(makeWAV(amplitude: 0.002))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try AudioValidation.hasAudibleSignal(at: url))
    }

    func testRejectsDitherLevelNoise() throws {
        // 0.0005 ≈ -66 dBFS — below the 0.001 default threshold.
        let url = try writeTemp(makeWAV(amplitude: 0.0005))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(try AudioValidation.hasAudibleSignal(at: url))
    }

    func testReturnsTrueOnUnreadableFile() throws {
        // 10 random bytes aren't a valid WAV — AVAudioFile will fail. We
        // conservatively return true so the real decoder surfaces the error.
        let url = try writeTemp(Data(repeating: 0x7f, count: 10))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(try AudioValidation.hasAudibleSignal(at: url))
    }

    // MARK: - AudioValidationError

    func testErrorDescriptionMentionsFilename() {
        let url = URL(fileURLWithPath: "/tmp/meeting.m4a")
        let err = AudioValidationError.silent(url)
        XCTAssertTrue(err.errorDescription?.contains("meeting.m4a") ?? false)
        XCTAssertTrue(err.errorDescription?.contains("silent") ?? false)
    }
}
