import Foundation

/// Estimates remaining time for a `0.0...1.0` progress stream using an
/// exponential moving average of the implied total time (`elapsed / progress`).
///
/// Mirrors the approach WhisperKit's CLI uses — progress under 5% is ignored
/// to avoid wild early estimates, and a smoothing factor of 0.1 is applied to
/// the running total.
final class ETAEstimator {
    /// Fraction of progress that must be observed before an estimate is returned.
    var warmupThreshold: Double = 0.05

    /// EMA smoothing factor for the estimated total duration.
    var smoothingFactor: Double = 0.1

    private var emaTotal: Double?

    /// Returns the estimated seconds remaining, or `nil` while warming up.
    func estimate(progress: Double, elapsed: TimeInterval) -> TimeInterval? {
        guard progress > warmupThreshold, progress < 1.0, elapsed > 0 else {
            return nil
        }
        let currentTotal = elapsed / progress
        let updated = emaTotal.map { $0 + smoothingFactor * (currentTotal - $0) } ?? currentTotal
        emaTotal = updated
        return max(updated - elapsed, 0)
    }

    func reset() {
        emaTotal = nil
    }
}
