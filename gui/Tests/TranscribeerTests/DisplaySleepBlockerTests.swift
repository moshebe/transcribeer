import Testing
@testable import TranscribeerApp

@MainActor
struct DisplaySleepBlockerTests {
    @Test("acquire and release are idempotent")
    func idempotent() {
        let blocker = DisplaySleepBlocker()
        #expect(!blocker.isActive)
        blocker.acquire()
        blocker.acquire()
        #expect(blocker.isActive)
        blocker.release()
        #expect(!blocker.isActive)
        blocker.release()
        #expect(!blocker.isActive)
    }
}
