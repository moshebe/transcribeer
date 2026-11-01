import Foundation

/// Operational budget derived from current device state (thermal, memory, power, chip).
/// Consumers use this to configure concurrency and inference behaviour without
/// knowing the underlying signals directly.
public struct TranscriptionBudget: Sendable, Equatable {
    /// Maximum number of parallel WhisperKit instances ChunkedTranscriber may create.
    public let maxConcurrency: Int
    /// False means force sequential processing even if maxConcurrency > 1.
    /// Set when memory pressure is critical.
    public let allowParallel: Bool

    public init(maxConcurrency: Int, allowParallel: Bool) {
        self.maxConcurrency = maxConcurrency
        self.allowParallel = allowParallel
    }

    public static let conservative = Self(
        maxConcurrency: 1, allowParallel: false
    )
    public static let standard = Self(
        maxConcurrency: 2, allowParallel: true
    )
    public static let performance = Self(
        maxConcurrency: 3, allowParallel: true
    )
}
