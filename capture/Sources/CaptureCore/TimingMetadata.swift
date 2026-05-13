import Foundation

/// Wall-clock timing information for a dual-source recording.
///
/// Written as `timing.json` in the session directory alongside the CAF
/// sidecars and the mixed `audio.m4a`.
public struct TimingMetadata: Codable, Equatable {
    public var micStartEpoch: TimeInterval?
    public var sysStartEpoch: TimeInterval?
    public var sysDeclaredSampleRate: Double
    public var sysEffectiveSampleRate: Double

    public init(
        micStartEpoch: TimeInterval? = nil,
        sysStartEpoch: TimeInterval? = nil,
        sysDeclaredSampleRate: Double = 0,
        sysEffectiveSampleRate: Double = 0
    ) {
        self.micStartEpoch = micStartEpoch
        self.sysStartEpoch = sysStartEpoch
        self.sysDeclaredSampleRate = sysDeclaredSampleRate
        self.sysEffectiveSampleRate = sysEffectiveSampleRate
    }

    /// Write JSON to disk.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(self)
        try data.write(to: url)
    }

    /// Read JSON from disk.
    public static func read(from url: URL) throws -> Self {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
