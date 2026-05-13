import Foundation
import Testing
@testable import CaptureCore

struct TimingMetadataTests {
    @Test("JSON round-trip preserves all fields")
    func roundTrip() throws {
        let original = TimingMetadata(
            micStartEpoch: 1_234_567.89,
            sysStartEpoch: 1_234_570.12,
            sysDeclaredSampleRate: 48000,
            sysEffectiveSampleRate: 47988.3
        )

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("timing_\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try original.write(to: url)
        let decoded = try TimingMetadata.read(from: url)

        #expect(decoded == original)
    }

    @Test("Default init produces zeros and nil epochs")
    func defaults() {
        let meta = TimingMetadata()
        #expect(meta.micStartEpoch == nil)
        #expect(meta.sysStartEpoch == nil)
        #expect(meta.sysDeclaredSampleRate == 0)
        #expect(meta.sysEffectiveSampleRate == 0)
    }
}
