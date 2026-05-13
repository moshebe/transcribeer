import AppKit
import Foundation
import os

/// Observes camera and microphone activation and correlates with running meeting apps
/// to decide whether the user is currently in a meeting.
///
/// Detection rules (ported from OpenOats):
/// - **Camera active** → immediate detection (trigger `.camera`). Treated as ground-truth
///   for video calls, even if no known meeting app is running (captures edge cases
///   like browser-based meeting rooms).
/// - **Camera off** → 3s hysteresis. If mic is still active AND a meeting app is still
///   running, downgrade trigger to `.micAndApp` and stay active; otherwise end.
/// - **Mic active for ≥5s** + a known meeting app in the running apps list → detect
///   with trigger `.micAndApp`.
/// - **Mic off** while triggered by `.micAndApp` → end immediately.
///
/// Mic alone never triggers (too noisy — voice memos, FaceTime audio apps, etc.).
@Observable
@MainActor
final class MeetingDetector {
    // Published state — observed by SwiftUI.
    private(set) var inMeeting = false
    private(set) var detectedApp: MeetingApp?
    private(set) var trigger: MeetingDetectionTrigger?

    // Dependencies.
    private let audioSource: any AudioSignalSource
    private let cameraSource: any CameraSignalSource
    private let processSource: any ProcessLifecycleSource
    /// Known apps in priority order — earlier entries win when multiple are running.
    private let prioritizedApps: [MeetingAppEntry]
    /// User-supplied bundle IDs, lowest priority after all known apps.
    private let customBundleIDs: [String]

    // Monitoring tasks.
    private var micStreamTask: Task<Void, Never>?
    private var cameraStreamTask: Task<Void, Never>?
    private var processStreamTask: Task<Void, Never>?
    private var micDebounceTask: Task<Void, Never>?
    private var cameraHysteresisTask: Task<Void, Never>?
    private var endGraceTask: Task<Void, Never>?
    /// Watchdog that polls `runningSnapshot()` while in-meeting. Backstop for
    /// missed `NSWorkspace.didTerminateApplicationNotification` events — in
    /// practice Zoom's `CptHost` helper sometimes quits without firing the
    /// notification, leaving the detector stuck in-meeting forever.
    private var endProcessPollTask: Task<Void, Never>?

    // Internal state.
    private var isCameraRunning = false
    private var isMicRunning = false
    private var micActiveAt: Date?
    /// Process whose termination ends the current detection. Set when detection
    /// begins with a known app; `nil` for camera-only (e.g. browser meeting).
    private var endProcessBundleID: String?

    private let debounceSeconds: TimeInterval = 5
    private let cameraHysteresisSeconds: TimeInterval = 3
    private let endGraceSeconds: TimeInterval = 3
    private let endProcessPollSeconds: TimeInterval = 3

    private let logger = Logger(subsystem: "com.transcribeer", category: "meeting-detector")

    init(
        audioSource: (any AudioSignalSource)? = nil,
        cameraSource: (any CameraSignalSource)? = nil,
        processSource: (any ProcessLifecycleSource)? = nil,
        apps: [MeetingAppEntry] = MeetingDetector.defaultMeetingApps,
        customBundleIDs: [String] = [],
    ) {
        self.audioSource = audioSource ?? CoreAudioSignalSource()
        self.cameraSource = cameraSource ?? CoreMediaIOSignalSource()
        self.processSource = processSource ?? NSWorkspaceProcessLifecycleSource()

        let selfBundle = Bundle.main.bundleIdentifier ?? "com.transcribeer"
        self.prioritizedApps = apps.filter { $0.bundleID != selfBundle }
        self.customBundleIDs = customBundleIDs.filter { $0 != selfBundle }
    }

    // MARK: - Lifecycle

    func start() {
        guard micStreamTask == nil else { return }
        logger.info("meeting detector started")

        let micSignals = audioSource.signals
        micStreamTask = Task { [weak self] in
            for await active in micSignals {
                guard !Task.isCancelled else { break }
                self?.handleMicSignal(active)
            }
        }

        let cameraSignals = cameraSource.signals
        cameraStreamTask = Task { [weak self] in
            for await active in cameraSignals {
                guard !Task.isCancelled else { break }
                self?.handleCameraSignal(active)
            }
        }

        let processEvents = processSource.events
        processStreamTask = Task { [weak self] in
            for await event in processEvents {
                guard !Task.isCancelled else { break }
                self?.handleProcessEvent(event)
            }
        }

        // Evaluate current state in case something is already running at launch.
        if audioSource.isActive { handleMicSignal(true) }
        if cameraSource.isActive { handleCameraSignal(true) }
    }

    func stop() {
        micStreamTask?.cancel()
        cameraStreamTask?.cancel()
        processStreamTask?.cancel()
        micDebounceTask?.cancel()
        cameraHysteresisTask?.cancel()
        endGraceTask?.cancel()
        endProcessPollTask?.cancel()
        micStreamTask = nil
        cameraStreamTask = nil
        processStreamTask = nil
        micDebounceTask = nil
        cameraHysteresisTask = nil
        endGraceTask = nil
        endProcessPollTask = nil

        if inMeeting {
            endDetection()
        }
        micActiveAt = nil
        isCameraRunning = false
        isMicRunning = false
    }

    // MARK: - Camera handling

    private func handleCameraSignal(_ active: Bool) {
        isCameraRunning = active

        if active {
            cameraHysteresisTask?.cancel()
            cameraHysteresisTask = nil
            let detected = scanForMeetingApp()
            if !inMeeting {
                beginDetection(
                    app: detected?.app,
                    endProcess: detected?.endProcessBundleID,
                    trigger: .camera,
                )
            } else {
                // Upgrade trigger to camera while both signals active.
                trigger = .camera
            }
        } else {
            cameraHysteresisTask?.cancel()
            let hysteresis = cameraHysteresisSeconds
            cameraHysteresisTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(hysteresis))
                guard !Task.isCancelled else { return }
                self?.evaluateCameraOff()
            }
        }
    }

    private func evaluateCameraOff() {
        guard inMeeting else { return }

        // If mic is still keeping a meeting app alive, downgrade trigger.
        if isMicRunning, micActiveAt != nil, detectedApp != nil {
            trigger = .micAndApp
            return
        }
        // Nothing sustains the detection any more.
        endDetection()
    }

    // MARK: - Mic handling

    private func handleMicSignal(_ active: Bool) {
        isMicRunning = active

        if active {
            if micActiveAt == nil { micActiveAt = Date() }
            scheduleMicDebounce()
        } else {
            micActiveAt = nil
            micDebounceTask?.cancel()
            micDebounceTask = nil
            if inMeeting, trigger == .micAndApp, !isCameraRunning {
                endDetection()
                return
            }
            // Mic releasing is a strong hint the meeting app has left the call.
            // Re-check immediately instead of waiting for the 3 s watchdog tick,
            // so auto-stop fires within a second of Zoom quitting the meeting.
            if inMeeting {
                evaluateEndProcessRunning()
            }
        }
    }

    private func scheduleMicDebounce() {
        guard let activeSince = micActiveAt else { return }
        micDebounceTask?.cancel()
        let debounce = debounceSeconds
        micDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(debounce))
            guard !Task.isCancelled else { return }
            self?.evaluateMicAfterDebounce(activeSince: activeSince)
        }
    }

    private func evaluateMicAfterDebounce(activeSince: Date) {
        // Mic went off during the sleep.
        guard let current = micActiveAt, current == activeSince else { return }
        // Already detected via camera — nothing to do.
        guard !inMeeting else { return }
        // Mic alone never triggers; require a meeting app.
        guard let detected = scanForMeetingApp() else { return }
        beginDetection(app: detected.app, endProcess: detected.endProcessBundleID, trigger: .micAndApp)
    }

    // MARK: - Process lifecycle handling

    private func handleProcessEvent(_ event: ProcessLifecycleEvent) {
        switch event {
        case .launched(let bundleID):
            // Watched process came back (e.g. user rejoined a Zoom meeting) while
            // a grace-period end was pending — cancel the pending end.
            guard bundleID == endProcessBundleID, endGraceTask != nil else { return }
            logger.info("end-process relaunched (\(bundleID, privacy: .public)) — cancelling grace")
            cancelEndGrace()

        case .terminated(let bundleID):
            guard inMeeting, bundleID == endProcessBundleID else { return }
            logger.info("end-process terminated (\(bundleID, privacy: .public)) — scheduling grace end")
            scheduleEndGrace()
        }
    }

    private func scheduleEndGrace() {
        let grace = endGraceSeconds
        cancelEndGrace()
        endGraceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard !Task.isCancelled else { return }
            self?.evaluateEndGrace()
        }
    }

    private func cancelEndGrace() {
        endGraceTask?.cancel()
        endGraceTask = nil
    }

    private func evaluateEndGrace() {
        endGraceTask = nil
        guard inMeeting else { return }
        endDetection()
    }

    // MARK: - Detection transitions

    private func beginDetection(app: MeetingApp?, endProcess: String?, trigger: MeetingDetectionTrigger) {
        inMeeting = true
        detectedApp = app
        endProcessBundleID = endProcess
        self.trigger = trigger
        cancelEndGrace()
        startEndProcessWatchdog()
        let summary = "trigger=\(trigger) app=\(app?.bundleID ?? "-") endProc=\(endProcess ?? "-")"
        logger.info("meeting detected \(summary, privacy: .public)")
    }

    private func endDetection() {
        logger.info("meeting ended")
        inMeeting = false
        detectedApp = nil
        endProcessBundleID = nil
        trigger = nil
        cancelEndGrace()
        stopEndProcessWatchdog()
    }

    // MARK: - End-process watchdog

    /// Start periodic `runningSnapshot()` polling while a meeting is active.
    /// Triggers `scheduleEndGrace()` when the keyed `endProcessBundleID` is no
    /// longer in the running set — covers the case where NSWorkspace's
    /// terminate notification is dropped (observed for `us.zoom.CptHost`).
    /// No-op when the current detection has no `endProcessBundleID`
    /// (e.g. browser-based meetings detected purely via camera).
    private func startEndProcessWatchdog() {
        stopEndProcessWatchdog()
        guard endProcessBundleID != nil else { return }
        let interval = endProcessPollSeconds
        endProcessPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self?.evaluateEndProcessRunning()
            }
        }
    }

    private func stopEndProcessWatchdog() {
        endProcessPollTask?.cancel()
        endProcessPollTask = nil
    }

    private func evaluateEndProcessRunning() {
        guard inMeeting,
              let bundleID = endProcessBundleID,
              endGraceTask == nil
        else { return }
        let running = Set(processSource.runningSnapshot().map(\.bundleID))
        if !running.contains(bundleID) {
            logger.info(
                "end-process \(bundleID, privacy: .public) no longer running (watchdog) — scheduling grace end",
            )
            scheduleEndGrace()
        }
    }

    // MARK: - Process scan

    /// Bundle ID of Zoom's meeting-only helper process. Spawns when a meeting
    /// starts, disappears when it ends — a reliable "Zoom is in a meeting" signal.
    nonisolated static let zoomMeetingHelperBundleID = "us.zoom.CptHost"
    nonisolated static let zoomBundleID = "us.zoom.xos"

    /// Result of `scanForMeetingApp` — pairs the user-facing `MeetingApp` with the
    /// process whose termination should end the session.
    private struct DetectedMeetingApp {
        let app: MeetingApp
        let endProcessBundleID: String
    }

    private func scanForMeetingApp() -> DetectedMeetingApp? {
        let snapshot = processSource.runningSnapshot()
        let runningBundleIDs = Set(snapshot.map(\.bundleID))

        guard let entry = Self.selectMeetingApp(
            running: runningBundleIDs,
            prioritizedApps: prioritizedApps,
            customBundleIDs: customBundleIDs,
        ) else { return nil }

        // Prefer the live localized name from the snapshot over the stored display
        // name, but fall back to it (and finally the bundle ID).
        let localizedName = snapshot.first { $0.bundleID == entry.bundleID }?.localizedName
        let app = MeetingApp(bundleID: entry.bundleID, name: localizedName ?? entry.displayName)
        return DetectedMeetingApp(app: app, endProcessBundleID: entry.effectiveEndProcessBundleID)
    }

    /// Pure selection logic — picks the highest-priority meeting app from a set of
    /// running bundle IDs. Extracted from the `NSWorkspace` scan so it can be unit-tested.
    ///
    /// Rules:
    /// 1. Zoom (`us.zoom.xos`) is only considered when its in-meeting helper
    ///    (`us.zoom.CptHost`) is also running — this rules out the "Zoom launched
    ///    but idle" false positive while another app is actually in a call.
    /// 2. `prioritizedApps` are scanned in array order — first match wins.
    /// 3. `customBundleIDs` are scanned last (lowest priority).
    static func selectMeetingApp(
        running: Set<String>,
        prioritizedApps: [MeetingAppEntry],
        customBundleIDs: [String],
    ) -> MeetingAppEntry? {
        let zoomInMeeting = running.contains(zoomMeetingHelperBundleID)
        let known = prioritizedApps.first { entry in
            guard running.contains(entry.bundleID) else { return false }
            // Only pick Zoom when it is confirmed to be in a meeting.
            return entry.bundleID != zoomBundleID || zoomInMeeting
        }
        if let known { return known }

        if let custom = customBundleIDs.first(where: running.contains) {
            return MeetingAppEntry(bundleID: custom, displayName: custom)
        }
        return nil
    }

    // MARK: - Known meeting apps

    /// Bundle IDs + display names for the apps we treat as meeting-capable.
    /// Listed in **priority order** — when multiple apps are running simultaneously,
    /// earlier entries win. Zoom / Slack / Teams are prioritized over chat apps
    /// that merely happen to also support calls (Discord, WhatsApp).
    nonisolated static let defaultMeetingApps: [MeetingAppEntry] = [
        MeetingAppEntry(
            bundleID: "us.zoom.xos",
            displayName: "Zoom",
            endProcessBundleID: zoomMeetingHelperBundleID,
        ),
        MeetingAppEntry(bundleID: "com.slack.Slack", displayName: "Slack"),
        MeetingAppEntry(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams"),
        MeetingAppEntry(bundleID: "com.microsoft.teams", displayName: "Microsoft Teams (classic)"),
        MeetingAppEntry(bundleID: "com.apple.FaceTime", displayName: "FaceTime"),
        MeetingAppEntry(bundleID: "com.cisco.webexmeetingsapp", displayName: "Webex"),
        MeetingAppEntry(
            bundleID: "com.google.Chrome.app.kjgfgldnnfobanmcafgkdilakhehfkbm",
            displayName: "Google Meet (PWA)",
        ),
        MeetingAppEntry(bundleID: "app.tuple.app", displayName: "Tuple"),
        MeetingAppEntry(bundleID: "co.around.Around", displayName: "Around"),
        MeetingAppEntry(bundleID: "net.whatsapp.WhatsApp", displayName: "WhatsApp"),
        MeetingAppEntry(bundleID: "com.hnc.Discord", displayName: "Discord"),
    ]
}
