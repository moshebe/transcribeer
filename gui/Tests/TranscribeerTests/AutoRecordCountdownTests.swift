import Testing
@testable import TranscribeerApp

@MainActor
struct AutoRecordCountdownTests {
    @Test("Zero delay starts recording without a title lookup")
    func startsImmediately() async {
        let countdown = AutoRecordCountdown(secondsRemaining: 0)
        var started = false
        await countdown.run {
            Issue.record("Immediate recording must not wait for Accessibility")
            return "Meeting"
        } onTick: { _, _ in
            Issue.record("Zero delay must not display a countdown")
        } onStart: { title in
            started = true
            #expect(title == nil)
        }
        #expect(started)
    }

    @Test("A countdown delivers its title and tick before starting")
    func startsAfterCountdown() async {
        let countdown = AutoRecordCountdown(secondsRemaining: 1)
        var events: [String] = []
        await countdown.run { "Meeting" } onTick: { seconds, title in
            #expect(seconds == 1)
            #expect(title == "Meeting")
            events.append("tick")
        } onStart: { title in
            #expect(title == "Meeting")
            events.append("start")
        }
        #expect(events == ["tick", "start"])
        #expect(countdown.secondsRemaining == 0)
    }

    @Test("Cancelling the visible countdown prevents recording")
    func cancellationPreventsStart() async {
        let countdown = AutoRecordCountdown(secondsRemaining: 1)
        var ticked = false
        var started = false
        countdown.task = Task {
            await countdown.run { nil } onTick: { _, _ in
                ticked = true
                countdown.task?.cancel()
            } onStart: { _ in
                started = true
            }
        }
        await countdown.task?.value
        #expect(ticked)
        #expect(!started)
    }
}
