import Foundation

/// Operational budget derived from current device state (thermal, memory, power, chip).
/// Consumers use this to configure concurrency and inference behaviour without
/// knowing the underlying signals directly.
public struct TranscriptionBudget: Sendable, Equatable {
    /// Maximum number of parallel WhisperKit instances ChunkedTranscriber may create.
    public let maxConcurrency: Int
    /// Whether to request ANE compute targets in WhisperKitConfig.
    public let allowANE: Bool
    /// False means force sequential processing even if maxConcurrency > 1.
    /// Set when memory pressure is critical.
    public let allowParallel: Bool
    /// Minutes after which TranscriptionService should auto-unload a model (0 = never).
    public let idleUnloadMinutes: Int

    public init(maxConcurrency: Int, allowANE: Bool, allowParallel: Bool, idleUnloadMinutes: Int) {
        self.maxConcurrency = maxConcurrency
        self.allowANE = allowANE
        self.allowParallel = allowParallel
        self.idleUnloadMinutes = idleUnloadMinutes
    }

    public static let conservative = Self(
        maxConcurrency: 1, allowANE: true, allowParallel: false, idleUnloadMinutes: 10
    )
    public static let standard = Self(
        maxConcurrency: 2, allowANE: true, allowParallel: true, idleUnloadMinutes: 10
    )
    public static let performance = Self(
        maxConcurrency: 3, allowANE: true, allowParallel: true, idleUnloadMinutes: 10
    )
}
