import Foundation
import Testing
@testable import TranscribeerApp

struct CloudRetryPolicyTests {
    // MARK: - Classification

    private static func http(_ status: Int, retryAfter: TimeInterval? = nil) -> TranscriptionError {
        .httpError(backend: "OpenAI", status: status, body: "", retryAfter: retryAfter)
    }

    static let retryableCases: [(String, any Error, Bool)] = [
        ("timedOut", URLError(.timedOut), true),
        ("networkConnectionLost", URLError(.networkConnectionLost), true),
        ("notConnectedToInternet", URLError(.notConnectedToInternet), true),
        ("cannotConnectToHost", URLError(.cannotConnectToHost), true),
        ("dnsLookupFailed", URLError(.dnsLookupFailed), true),
        ("cannotFindHost", URLError(.cannotFindHost), true),
        ("URLError cancelled", URLError(.cancelled), false),
        ("URLError badURL", URLError(.badURL), false),
        ("HTTP 408", http(408), true),
        ("HTTP 429", http(429), true),
        ("HTTP 500", http(500), true),
        ("HTTP 502", http(502), true),
        ("HTTP 503", http(503), true),
        ("HTTP 504", http(504), true),
        ("HTTP 400", http(400), false),
        ("HTTP 401", http(401), false),
        ("HTTP 403", http(403), false),
        ("HTTP 404", http(404), false),
        ("invalid response", TranscriptionError.invalidResponse(backend: "Gemini", detail: "x"), false),
        ("missing key", TranscriptionError.missingAPIKey(backend: "OpenAI", envVar: ""), false),
        ("cancellation", CancellationError(), false),
    ]

    @Test("isRetryable classifies transient vs permanent errors", arguments: retryableCases)
    func isRetryable(name: String, error: any Error, expected: Bool) {
        #expect(CloudRetryPolicy.isRetryable(error) == expected, "\(name)")
    }

    // MARK: - Backoff

    @Test("Backoff stays within [ceiling/2, ceiling] and caps at maxDelay", arguments: [
        (1, 2.0), (2, 4.0), (3, 8.0), (4, 16.0), (5, 30.0), (10, 30.0),
    ])
    func backoffBounds(attempt: Int, ceiling: Double) {
        let policy = CloudRetryPolicy()
        #expect(policy.backoffCeiling(forAttempt: attempt) == ceiling)
        #expect(policy.delay(forAttempt: attempt, jitter: 0) == ceiling / 2)
        #expect(policy.delay(forAttempt: attempt, jitter: 1) == ceiling)
        for _ in 0..<50 {
            let delay = policy.delay(forAttempt: attempt, jitter: Double.random(in: 0...1))
            #expect(delay >= ceiling / 2 && delay <= ceiling)
        }
    }

    @Test("Retry-After raises the delay, clamped to maxRetryAfter", arguments: [
        (nil, 1.0),
        (0.5, 1.0),
        (20.0, 20.0),
        (600.0, 60.0),
    ] as [(TimeInterval?, TimeInterval)])
    func retryAfterHonoured(retryAfter: TimeInterval?, expected: TimeInterval) {
        let delay = CloudRetryPolicy().delay(forAttempt: 1, jitter: 0, retryAfter: retryAfter)
        #expect(delay == expected)
    }

    @Test("Retry-After hint only used for 429/503")
    func retryAfterOnlyForRateLimitStatuses() {
        #expect(CloudRetryPolicy.retryAfter(for: Self.http(429, retryAfter: 7)) == 7)
        #expect(CloudRetryPolicy.retryAfter(for: Self.http(503, retryAfter: 7)) == 7)
        #expect(CloudRetryPolicy.retryAfter(for: Self.http(500, retryAfter: 7)) == nil)
    }

    @Test("Retry-After header parsing", arguments: [
        ("12", 12.0),
        (" 3 ", 3.0),
        ("Wed, 21 Oct 2015 07:28:00 GMT", nil),
        ("-1", nil),
        (nil, nil),
    ] as [(String?, TimeInterval?)])
    func parseRetryAfter(value: String?, expected: TimeInterval?) {
        #expect(CloudRetryPolicy.parseRetryAfter(value) == expected)
    }

    // MARK: - Execution

    @Test("Flaky operation succeeds after transient failures")
    func flakySucceeds() async throws {
        let counter = Counter()
        let sleeps = Counter()
        var events: [CloudRetryPolicy.RetryEvent] = []
        let result = try await CloudRetryPolicy().run(
            sleep: { _ in sleeps.increment() },
            jitter: { 0 },
            onRetry: { events.append($0) },
            operation: {
                let n = counter.increment()
                if n < 4 { throw URLError(.networkConnectionLost) }
                return "ok"
            }
        )
        #expect(result == "ok")
        #expect(counter.value == 4)
        #expect(sleeps.value == 3)
        #expect(events.map(\.failedAttempt) == [1, 2, 3])
        #expect(events.map(\.delay) == [1, 2, 4])
        #expect(events.allSatisfy { $0.reason == "URLError \(URLError.Code.networkConnectionLost.rawValue)" })
    }

    @Test("Gives up after maxAttempts and rethrows the last error")
    func exhaustsAttempts() async {
        let counter = Counter()
        await #expect(throws: TranscriptionError.self) {
            try await CloudRetryPolicy().run(
                sleep: { _ in },
                operation: { () async throws -> Int in
                    counter.increment()
                    throw Self.http(503)
                }
            )
        }
        #expect(counter.value == 4)
    }

    @Test("Non-retryable error fails immediately without sleeping")
    func nonRetryableFailsFast() async {
        let counter = Counter()
        let sleeps = Counter()
        await #expect(throws: TranscriptionError.self) {
            try await CloudRetryPolicy().run(
                sleep: { _ in sleeps.increment() },
                operation: { () async throws -> Int in
                    counter.increment()
                    throw Self.http(401)
                }
            )
        }
        #expect(counter.value == 1)
        #expect(sleeps.value == 0)
    }

    @Test("Cancellation during backoff sleep stops retrying")
    func cancellationStopsRetry() async {
        let counter = Counter()
        let task = Task {
            try await CloudRetryPolicy(baseDelay: 60).run(operation: { () async throws -> Int in
                counter.increment()
                throw URLError(.timedOut)
            })
        }
        while counter.value == 0 { await Task.yield() }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(counter.value == 1)
    }
}

// MARK: - Helpers

/// Thread-safe counter for `@Sendable` closures in tests.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
