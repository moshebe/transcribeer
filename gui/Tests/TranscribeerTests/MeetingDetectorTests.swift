import Foundation
import Testing
@testable import TranscribeerApp

// MARK: - Mock Signal Sources

/// Replays a scripted sequence of process lifecycle events to the detector.
/// Also acts as the running-apps snapshot source — pre-seed `setRunning(_:)`
/// before starting detection to make `scanForMeetingApp` deterministic.
final class MockProcessLifecycleSource: ProcessLifecycleSource, @unchecked Sendable {
    let events: AsyncStream<ProcessLifecycleEvent>
    private let continuation: AsyncStream<ProcessLifecycleEvent>.Continuation
    private let lock = NSLock()
    private var running: [RunningAppSnapshot] = []

    init() {
        let (stream, capturedContinuation) = AsyncStream.makeStream(of: ProcessLifecycleEvent.self)
        self.events = stream
        self.continuation = capturedContinuation
    }

    func runningSnapshot() -> [RunningAppSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// Replace the set of "currently running" apps used by `runningSnapshot()`.
    func setRunning(_ apps: [RunningAppSnapshot]) {
        lock.lock()
        running = apps
        lock.unlock()
    }

    /// Emit a termination event and remove the app from the running snapshot.
    func terminate(bundleID: String) {
        lock.lock()
        running.removeAll { $0.bundleID == bundleID }
        lock.unlock()
        continuation.yield(.terminated(bundleID: bundleID))
    }

    /// Emit a launch event and add the app to the running snapshot.
    func launch(bundleID: String, localizedName: String? = nil) {
        lock.lock()
        if !running.contains(where: { $0.bundleID == bundleID }) {
            running.append(RunningAppSnapshot(bundleID: bundleID, localizedName: localizedName))
        }
        lock.unlock()
        continuation.yield(.launched(bundleID: bundleID))
    }

    func emit(_ event: ProcessLifecycleEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
}

/// Replays a scripted sequence of signal values to the detector's AsyncStream.
final class MockSignalSource: AudioSignalSource, CameraSignalSource, @unchecked Sendable {
    let signals: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation
    private var currentValue = false
    private let lock = NSLock()

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return currentValue
    }

    init() {
        let (stream, capturedContinuation) = AsyncStream.makeStream(of: Bool.self)
        self.signals = stream
        self.continuation = capturedContinuation
    }

    func emit(_ value: Bool) {
        lock.lock()
        currentValue = value
        lock.unlock()
        continuation.yield(value)
    }

    func finish() {
        continuation.finish()
    }
}

// MARK: - Tests

@MainActor
struct MeetingDetectorTests {
    @Test("camera on triggers detection immediately even without a meeting app")
    func cameraOnTriggersImmediately() async {
        let audio = MockSignalSource()
        let camera = MockSignalSource()
        let detector = MeetingDetector(audioSource: audio, cameraSource: camera)
        detector.start()
        defer { detector.stop() }

        camera.emit(true)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(detector.inMeeting)
        #expect(detector.trigger == .camera)
    }

    @Test("camera off ends detection after hysteresis when mic is not sustaining it")
    func cameraOffEndsDetection() async {
        let audio = MockSignalSource()
        let camera = MockSignalSource()
        let detector = MeetingDetector(audioSource: audio, cameraSource: camera)
        detector.start()
        defer { detector.stop() }

        camera.emit(true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(detector.inMeeting)

        camera.emit(false)
        // Hysteresis is 3s; wait slightly longer.
        try? await Task.sleep(for: .seconds(4))

        #expect(!detector.inMeeting)
        #expect(detector.trigger == nil)
    }

    @Test("mic alone never triggers detection without a meeting app running")
    func micAloneDoesNotTrigger() async {
        let audio = MockSignalSource()
        let camera = MockSignalSource()
        // Empty app list → no process scan can ever match.
        let detector = MeetingDetector(audioSource: audio, cameraSource: camera, apps: [])
        detector.start()
        defer { detector.stop() }

        audio.emit(true)
        // Debounce is 5s; if it were going to fire it would have fired by now.
        try? await Task.sleep(for: .seconds(6))

        #expect(!detector.inMeeting)
    }

    @Test("mic off during debounce cancels pending detection")
    func micOffDuringDebounceCancels() async {
        let audio = MockSignalSource()
        let camera = MockSignalSource()
        let detector = MeetingDetector(audioSource: audio, cameraSource: camera)
        detector.start()
        defer { detector.stop() }

        audio.emit(true)
        try? await Task.sleep(for: .seconds(1))
        audio.emit(false)
        try? await Task.sleep(for: .seconds(5))

        #expect(!detector.inMeeting)
    }

    @Test("default app list contains the key video-conf bundles")
    func defaultAppList() {
        let bundles = Set(MeetingDetector.defaultMeetingApps.map(\.bundleID))
        #expect(bundles.contains("us.zoom.xos"))
        #expect(bundles.contains("com.microsoft.teams2"))
        #expect(bundles.contains("com.apple.FaceTime"))
        #expect(bundles.contains("com.cisco.webexmeetingsapp"))
        #expect(bundles.contains("com.google.Chrome.app.kjgfgldnnfobanmcafgkdilakhehfkbm"))
    }

    @Test("default priority order: Zoom > Slack > Teams > everything else")
    func defaultPriorityOrder() {
        let order = MeetingDetector.defaultMeetingApps.map(\.bundleID)
        let zoom = order.firstIndex(of: "us.zoom.xos")
        let slack = order.firstIndex(of: "com.slack.Slack")
        let teamsNew = order.firstIndex(of: "com.microsoft.teams2")
        let teamsOld = order.firstIndex(of: "com.microsoft.teams")
        let discord = order.firstIndex(of: "com.hnc.Discord")

        #expect(zoom != nil && slack != nil && teamsNew != nil)
        #expect((zoom ?? -1) < (slack ?? -1))
        #expect((slack ?? -1) < (teamsNew ?? -1))
        #expect((teamsNew ?? -1) < (teamsOld ?? -1))
        #expect((teamsOld ?? -1) < (discord ?? Int.max))
    }

    // MARK: - selectMeetingApp priority logic

    @Test("Zoom with its meeting helper wins over Discord")
    func zoomMeetingBeatsDiscord() {
        let running: Set<String> = ["us.zoom.xos", MeetingDetector.zoomMeetingHelperBundleID, "com.hnc.Discord"]
        let selected = MeetingDetector.selectMeetingApp(
            running: running,
            prioritizedApps: MeetingDetector.defaultMeetingApps,
            customBundleIDs: [],
        )
        #expect(selected?.bundleID == "us.zoom.xos")
    }

    @Test("Zoom idle (no CptHost) is skipped — Discord wins when it's the only meeting app")
    func zoomIdleSkipped() {
        let running: Set<String> = ["us.zoom.xos", "com.hnc.Discord"]
        let selected = MeetingDetector.selectMeetingApp(
            running: running,
            prioritizedApps: MeetingDetector.defaultMeetingApps,
            customBundleIDs: [],
        )
        #expect(selected?.bundleID == "com.hnc.Discord")
    }

    @Test("Slack beats Teams when both are running")
    func slackBeatsTeams() {
        let running: Set<String> = ["com.slack.Slack", "com.microsoft.teams2"]
        let selected = MeetingDetector.selectMeetingApp(
            running: running,
            prioritizedApps: MeetingDetector.defaultMeetingApps,
            customBundleIDs: [],
        )
        #expect(selected?.bundleID == "com.slack.Slack")
    }

    @Test("Teams beats Discord when both are running")
    func teamsBeatsDiscord() {
        let running: Set<String> = ["com.microsoft.teams2", "com.hnc.Discord"]
        let selected = MeetingDetector.selectMeetingApp(
            running: running,
            prioritizedApps: MeetingDetector.defaultMeetingApps,
            customBundleIDs: [],
        )
        #expect(selected?.bundleID == "com.microsoft.teams2")
    }

    @Test("Custom bundle IDs are last-resort when no known app is running")
    func customBundleFallback() {
        let running: Set<String> = ["com.example.custom-meeting-app"]
        let selected = MeetingDetector.selectMeetingApp(
            running: running,
            prioritizedApps: MeetingDetector.defaultMeetingApps,
            customBundleIDs: ["com.example.custom-meeting-app"],
        )
        #expect(selected?.bundleID == "com.example.custom-meeting-app")
    }

    @Test("Known app beats custom bundle ID even at lower priority")
    func knownBeatsCustom() {
        let running: Set<String> = ["com.hnc.Discord", "com.example.custom"]
        let selected = MeetingDetector.selectMeetingApp(
            running: running,
            prioritizedApps: MeetingDetector.defaultMeetingApps,
            customBundleIDs: ["com.example.custom"],
        )
        #expect(selected?.bundleID == "com.hnc.Discord")
    }

    @Test("No running app matches → returns nil")
    func noMatch() {
        let selected = MeetingDetector.selectMeetingApp(
            running: ["com.apple.Safari", "com.apple.Finder"],
            prioritizedApps: MeetingDetector.defaultMeetingApps,
            customBundleIDs: [],
        )
        #expect(selected == nil)
    }

    @Test("stop() cancels pending detection and clears state")
    func stopClearsState() async {
        let audio = MockSignalSource()
        let camera = MockSignalSource()
        let detector = MeetingDetector(audioSource: audio, cameraSource: camera)
        detector.start()

        camera.emit(true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(detector.inMeeting)

        detector.stop()
        #expect(!detector.inMeeting)
        #expect(detector.detectedApp == nil)
        #expect(detector.trigger == nil)
    }

    // MARK: - Process-lifecycle end detection

    /// Boots a detector with a single known app, pre-seeds the running-snapshot,
    /// and fires a camera trigger for immediate detection (bypasses mic debounce).
    private func startCameraDetection(
        bundleID: String,
        endProcess: String,
    ) -> (MeetingDetector, MockProcessLifecycleSource) {
        let audio = MockSignalSource()
        let camera = MockSignalSource()
        let process = MockProcessLifecycleSource()
        process.setRunning([
            RunningAppSnapshot(bundleID: bundleID, localizedName: "Test App"),
            // Zoom only counts as in-meeting when CptHost is also running.
            RunningAppSnapshot(bundleID: endProcess, localizedName: nil),
        ])
        let apps = [
            MeetingAppEntry(bundleID: bundleID, displayName: "Test App", endProcessBundleID: endProcess),
        ]
        let detector = MeetingDetector(
            audioSource: audio,
            cameraSource: camera,
            processSource: process,
            apps: apps,
        )
        detector.start()
        camera.emit(true)
        return (detector, process)
    }

    @Test("Zoom CptHost termination ends detection after grace period")
    func cptHostTerminationEndsDetection() async {
        let (detector, process) = startCameraDetection(
            bundleID: "us.zoom.xos",
            endProcess: "us.zoom.CptHost",
        )
        defer { detector.stop() }

        try? await Task.sleep(for: .milliseconds(100))
        #expect(detector.inMeeting)
        #expect(detector.detectedApp?.bundleID == "us.zoom.xos")

        process.terminate(bundleID: "us.zoom.CptHost")
        // Grace is 3s — wait slightly longer.
        try? await Task.sleep(for: .seconds(4))

        #expect(!detector.inMeeting)
        #expect(detector.detectedApp == nil)
        #expect(detector.trigger == nil)
    }

    @Test("Non-Zoom app termination ends detection (falls back to main bundle)")
    func mainAppTerminationEndsDetection() async {
        let (detector, process) = startCameraDetection(
            bundleID: "com.microsoft.teams2",
            endProcess: "com.microsoft.teams2",
        )
        defer { detector.stop() }

        try? await Task.sleep(for: .milliseconds(100))
        #expect(detector.inMeeting)

        process.terminate(bundleID: "com.microsoft.teams2")
        try? await Task.sleep(for: .seconds(4))

        #expect(!detector.inMeeting)
    }

    @Test("Unrelated app termination does not end detection")
    func unrelatedTerminationIgnored() async {
        let (detector, process) = startCameraDetection(
            bundleID: "us.zoom.xos",
            endProcess: "us.zoom.CptHost",
        )
        defer { detector.stop() }

        try? await Task.sleep(for: .milliseconds(100))
        #expect(detector.inMeeting)

        process.terminate(bundleID: "com.apple.Safari")
        try? await Task.sleep(for: .seconds(4))

        #expect(detector.inMeeting)
    }

    @Test("End-process silently disappearing is caught by watchdog")
    func silentEndProcessDisappearsEndsDetection() async {
        let (detector, process) = startCameraDetection(
            bundleID: "us.zoom.xos",
            endProcess: "us.zoom.CptHost",
        )
        defer { detector.stop() }

        try? await Task.sleep(for: .milliseconds(100))
        #expect(detector.inMeeting)

        // Simulate the notification being dropped: remove from runningSnapshot
        // without firing a `.terminated` event.
        process.setRunning([
            RunningAppSnapshot(bundleID: "us.zoom.xos", localizedName: "Zoom"),
        ])

        // Watchdog polls every 3 s and then schedules a 3 s grace — allow ~7 s.
        try? await Task.sleep(for: .seconds(7))

        #expect(!detector.inMeeting)
        #expect(detector.detectedApp == nil)
    }

    @Test("Mic off + end-process gone ends detection without waiting for watchdog tick")
    func micOffWithGoneEndProcessEndsQuickly() async {
        let audio = MockSignalSource()
        let camera = MockSignalSource()
        let process = MockProcessLifecycleSource()
        process.setRunning([
            RunningAppSnapshot(bundleID: "us.zoom.xos", localizedName: "Zoom"),
            RunningAppSnapshot(bundleID: "us.zoom.CptHost", localizedName: nil),
        ])
        let apps = [
            MeetingAppEntry(
                bundleID: "us.zoom.xos",
                displayName: "Zoom",
                endProcessBundleID: "us.zoom.CptHost",
            ),
        ]
        let detector = MeetingDetector(
            audioSource: audio,
            cameraSource: camera,
            processSource: process,
            apps: apps,
        )
        detector.start()
        defer { detector.stop() }

        camera.emit(true)
        audio.emit(true)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(detector.inMeeting)

        // Zoom call ends: CptHost quits and mic is released. NSWorkspace's
        // terminate notification is intentionally NOT fired to model the
        // observed production bug.
        process.setRunning([
            RunningAppSnapshot(bundleID: "us.zoom.xos", localizedName: "Zoom"),
        ])
        audio.emit(false)

        // Only the 3 s grace is needed — mic-off kicks the evaluate path.
        try? await Task.sleep(for: .seconds(4))

        #expect(!detector.inMeeting)
    }

    @Test("Mic off while end-process still running keeps detection (mute/unmute flow)")
    func micOffWithRunningEndProcessStaysInMeeting() async {
        let audio = MockSignalSource()
        let camera = MockSignalSource()
        let process = MockProcessLifecycleSource()
        process.setRunning([
            RunningAppSnapshot(bundleID: "us.zoom.xos", localizedName: "Zoom"),
            RunningAppSnapshot(bundleID: "us.zoom.CptHost", localizedName: nil),
        ])
        let apps = [
            MeetingAppEntry(
                bundleID: "us.zoom.xos",
                displayName: "Zoom",
                endProcessBundleID: "us.zoom.CptHost",
            ),
        ]
        let detector = MeetingDetector(
            audioSource: audio,
            cameraSource: camera,
            processSource: process,
            apps: apps,
        )
        detector.start()
        defer { detector.stop() }

        camera.emit(true)
        audio.emit(true)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(detector.inMeeting)

        // User mutes: mic goes silent but the call is still active.
        audio.emit(false)
        try? await Task.sleep(for: .milliseconds(200))

        #expect(detector.inMeeting)
    }

    @Test("End-process relaunch during grace cancels the pending end")
    func relaunchDuringGraceCancelsEnd() async {
        let (detector, process) = startCameraDetection(
            bundleID: "us.zoom.xos",
            endProcess: "us.zoom.CptHost",
        )
        defer { detector.stop() }

        try? await Task.sleep(for: .milliseconds(100))
        #expect(detector.inMeeting)

        process.terminate(bundleID: "us.zoom.CptHost")
        try? await Task.sleep(for: .seconds(1))
        process.launch(bundleID: "us.zoom.CptHost")
        // Wait past the original 3s grace — detection should still be active.
        try? await Task.sleep(for: .seconds(3))

        #expect(detector.inMeeting)
    }
}
