import AppKit
import Foundation

// MARK: - Process Lifecycle Source

/// Lifecycle event for a running application.
enum ProcessLifecycleEvent: Sendable, Equatable {
    case launched(bundleID: String)
    case terminated(bundleID: String)
}

/// Observes application launch/termination across the system.
///
/// Injected into `MeetingDetector` so meeting-end can be detected when the
/// process that keyed the meeting exits (e.g. Zoom's `us.zoom.CptHost` helper),
/// even while we are still holding the mic ourselves for recording.
protocol ProcessLifecycleSource: Sendable {
    var events: AsyncStream<ProcessLifecycleEvent> { get }

    /// Snapshot of currently running applications, keyed by bundle ID. Used by
    /// `MeetingDetector.scanForMeetingApp` so the full flow can be driven from
    /// a single injectable source in tests.
    func runningSnapshot() -> [RunningAppSnapshot]
}

/// Minimal info we need from a running application — bundle ID plus the user-
/// facing localized name (so `MeetingApp.name` stays accurate).
struct RunningAppSnapshot: Sendable, Equatable {
    let bundleID: String
    let localizedName: String?
}

// MARK: - NSWorkspace-backed source

/// Production `ProcessLifecycleSource` bridging NSWorkspace launch/terminate notifications.
///
/// Subscribes on the main queue — callbacks flow through the shared workspace
/// notification center and are translated into a single `AsyncStream` so callers
/// can observe launch/termination without juggling two separate observers.
final class NSWorkspaceProcessLifecycleSource: ProcessLifecycleSource, @unchecked Sendable {
    let events: AsyncStream<ProcessLifecycleEvent>
    private let continuation: AsyncStream<ProcessLifecycleEvent>.Continuation
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?

    init() {
        let (stream, capturedContinuation) = AsyncStream.makeStream(of: ProcessLifecycleEvent.self)
        self.events = stream
        self.continuation = capturedContinuation

        launchObserver = observe(NSWorkspace.didLaunchApplicationNotification) { .launched(bundleID: $0) }
        terminateObserver = observe(NSWorkspace.didTerminateApplicationNotification) { .terminated(bundleID: $0) }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        if let launchObserver { center.removeObserver(launchObserver) }
        if let terminateObserver { center.removeObserver(terminateObserver) }
        continuation.finish()
    }

    func runningSnapshot() -> [RunningAppSnapshot] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return RunningAppSnapshot(bundleID: bundleID, localizedName: app.localizedName)
        }
    }

    /// Register a main-queue observer that extracts the app's bundle ID from the
    /// notification and yields a lifecycle event built by `event(bundleID:)`.
    private func observe(
        _ name: Notification.Name,
        event: @escaping @Sendable (String) -> ProcessLifecycleEvent,
    ) -> NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main,
        ) { [weak self] note in
            guard let bundleID = Self.bundleID(from: note) else { return }
            self?.continuation.yield(event(bundleID))
        }
    }

    private static func bundleID(from note: Notification) -> String? {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier
    }
}
