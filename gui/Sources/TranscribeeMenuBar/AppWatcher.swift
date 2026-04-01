import AppKit

class AppWatcher: ObservableObject {
    @Published var activeMeetingApp: String? = nil

    private let watched: [String: String] = [
        "us.zoom.xos":          "Zoom",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams":  "Teams",
        "com.loom.desktop":     "Loom",
    ]

    private var observers: [NSObjectProtocol] = []

    func startWatching(runner: TranscribeeRunner) {
        // Check already-running apps at launch
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, let name = watched[id] {
                DispatchQueue.main.async { self.activeMeetingApp = name }
                break
            }
        }

        let nc = NSWorkspace.shared.notificationCenter

        let launchObs = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier,
                  let name = self.watched[id] else { return }
            DispatchQueue.main.async { self.activeMeetingApp = name }
        }

        let terminateObs = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier,
                  self.watched[id] != nil else { return }
            DispatchQueue.main.async {
                self.activeMeetingApp = nil
                if case .recording = runner.state {
                    runner.stop()
                }
            }
        }

        observers = [launchObs, terminateObs]
    }
}
