import Foundation
import Testing
@testable import TranscribeerApp

@MainActor
struct ZoomParticipantsWatcherTests {
    @Test("Participant reads run off the main thread and publish their result")
    func readsInBackground() async {
        let watcher = ZoomParticipantsWatcher(lookup: {
            #expect(Thread.isMainThread == false)
            return .init(state: .panelClosed, snapshot: nil)
        })

        await watcher.pollOnce()

        #expect(watcher.lastState == .panelClosed)
    }

    @Test("Cancelled participant reads do not publish a late result", .timeLimit(.minutes(1)))
    func discardsCancelledRead() async {
        let (started, continuation) = AsyncStream.makeStream(of: Void.self)
        let release = DispatchSemaphore(value: 0)
        let watcher = ZoomParticipantsWatcher(lookup: {
            #expect(Thread.isMainThread == false)
            continuation.yield(())
            release.wait()
            return .init(state: .panelClosed, snapshot: nil)
        })
        let poll = Task { await watcher.pollOnce() }
        var iterator = started.makeAsyncIterator()
        await iterator.next()

        poll.cancel()
        release.signal()
        await poll.value
        continuation.finish()

        #expect(watcher.lastState == nil)
        #expect(watcher.snapshot == nil)
    }
}
