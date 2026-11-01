import Foundation
import os.log

/// Retry policy for a single cloud transcription chunk.
///
/// Only transient failures are retried: network-level `URLError`s and the
/// HTTP statuses providers use for overload / rate limiting. Client errors
/// (400/401/403/404), decode failures and cancellation fail immediately so
/// the user sees the real problem without waiting through backoff.
///
/// Backoff is exponential with "equal jitter": retry `n` waits a random
/// duration in `[ceiling / 2, ceiling]`, where
/// `ceiling = min(maxDelay, baseDelay * 2^(n-1))`. A server-provided
/// `Retry-After` (429/503) raises the wait to at least that value, clamped
/// to `maxRetryAfter` so a hostile header can't stall a recording forever.
struct CloudRetryPolicy: Sendable {
    /// Total attempts including the first call (so `maxAttempts - 1` retries).
    var maxAttempts = 4
    var baseDelay: TimeInterval = 2
    var maxDelay: TimeInterval = 30
    var maxRetryAfter: TimeInterval = 60

    /// Details handed to the `onRetry` hook before each backoff sleep.
    struct RetryEvent: Sendable {
        /// 1-based number of the attempt that just failed.
        let failedAttempt: Int
        let maxAttempts: Int
        let delay: TimeInterval
        let reason: String
    }

    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    /// Default sleeper. `Task.sleep` throws `CancellationError` when the
    /// surrounding task is cancelled, which aborts the retry loop.
    static let taskSleep: Sleeper = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }

    static let transientURLErrorCodes: Set<URLError.Code> = [
        .timedOut,
        .networkConnectionLost,
        .notConnectedToInternet,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .cannotFindHost,
    ]

    static let transientHTTPStatuses: Set<Int> = [408, 429, 500, 502, 503, 504]

    // MARK: - Classification

    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError {
            return transientURLErrorCodes.contains(urlError.code)
        }
        if case let .httpError(_, status, _, _) = error as? TranscriptionError {
            return transientHTTPStatuses.contains(status)
        }
        return false
    }

    /// Short, content-free description for logs (no response bodies).
    static func reason(for error: Error) -> String {
        if let urlError = error as? URLError {
            return "URLError \(urlError.code.rawValue)"
        }
        if case let .httpError(_, status, _, _) = error as? TranscriptionError {
            return "HTTP \(status)"
        }
        return String(describing: type(of: error))
    }

    // MARK: - Backoff

    /// Upper bound of the backoff before retry number `attempt` (1-based).
    func backoffCeiling(forAttempt attempt: Int) -> TimeInterval {
        let exponent = Double(max(0, attempt - 1))
        return min(maxDelay, baseDelay * pow(2, exponent))
    }

    /// Delay before retry number `attempt` (1-based). `jitter` is a unit
    /// random value in `0...1`; `retryAfter` is the server hint, if any.
    func delay(
        forAttempt attempt: Int,
        jitter: Double,
        retryAfter: TimeInterval? = nil
    ) -> TimeInterval {
        let ceiling = backoffCeiling(forAttempt: attempt)
        let clampedJitter = min(1, max(0, jitter))
        let backoff = ceiling / 2 + ceiling / 2 * clampedJitter
        guard let retryAfter, retryAfter > 0 else { return backoff }
        return max(backoff, min(retryAfter, maxRetryAfter))
    }

    /// `Retry-After` hint carried by a 429/503 error, if present.
    static func retryAfter(for error: Error) -> TimeInterval? {
        guard case let .httpError(_, status, _, retryAfter) = error as? TranscriptionError,
              status == 429 || status == 503 else { return nil }
        return retryAfter
    }

    /// Parse a `Retry-After` header value. Only the delta-seconds form is
    /// supported; OpenAI and Google both send seconds. HTTP-date values
    /// are ignored (plain exponential backoff applies).
    static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let value,
              let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)),
              seconds >= 0 else { return nil }
        return seconds
    }

    // MARK: - Execution

    /// Run `operation`, retrying transient failures with backoff. The last
    /// error is rethrown once attempts are exhausted or a non-retryable
    /// error occurs.
    func run<T: Sendable>(
        sleep: Sleeper = Self.taskSleep,
        jitter: @Sendable () -> Double = { Double.random(in: 0...1) },
        onRetry: (RetryEvent) -> Void = { _ in },
        operation: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                return try await operation()
            } catch {
                guard attempt < maxAttempts, Self.isRetryable(error) else { throw error }
                let wait = delay(
                    forAttempt: attempt,
                    jitter: jitter(),
                    retryAfter: Self.retryAfter(for: error)
                )
                onRetry(RetryEvent(
                    failedAttempt: attempt,
                    maxAttempts: maxAttempts,
                    delay: wait,
                    reason: Self.reason(for: error)
                ))
                try await sleep(wait)
                attempt += 1
            }
        }
    }
}

// MARK: - Logging

extension CloudRetryPolicy.RetryEvent {
    private static let logger = Logger(subsystem: "com.transcribeer", category: "CloudTranscription")

    /// Log this retry for chunk `index`. Only the status / error code is
    /// logged, never response bodies or transcript content.
    func log(chunk index: Int, backend: TranscriptionBackend) {
        Self.logger.warning(
            """
            chunk retry index=\(index, privacy: .public) \
            backend=\(backend.rawValue, privacy: .public) \
            attempt=\(failedAttempt, privacy: .public)/\(maxAttempts, privacy: .public) \
            delay=\(delay, format: .fixed(precision: 1), privacy: .public)s \
            reason=\(reason, privacy: .public)
            """
        )
    }
}
