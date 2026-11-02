import Foundation
import Observation

@Observable
@MainActor
final class AutoRecordCountdown {
    var secondsRemaining: Int
    @ObservationIgnored var task: Task<Void, Never>?

    init(secondsRemaining: Int) {
        self.secondsRemaining = max(0, secondsRemaining)
    }

    func run(
        readTitle: () async -> String?,
        onTick: (Int, String?) -> Void,
        onStart: (String?) -> Void
    ) async {
        // Immediate recording gets its title from the runner's background polling.
        let title = secondsRemaining > 0 ? await readTitle() : nil
        guard !Task.isCancelled else { return }
        while secondsRemaining > 0 {
            onTick(secondsRemaining, title)
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            secondsRemaining -= 1
        }
        guard !Task.isCancelled else { return }
        onStart(title)
    }
}
