import Foundation

/// Serializes tests that replace `DualSourceTranscriber`'s global test seams.
/// Swift Testing runs tests in parallel, and `.serialized` does not protect
/// non-parameterized tests, so shared mutable seams need an explicit async lock.
actor DualSourceTranscriberMockLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async throws -> T {
        await acquire()
        defer { releaseNext() }
        return try await operation()
    }

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseNext() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}

let dualSourceTranscriberMockLock = DualSourceTranscriberMockLock()
