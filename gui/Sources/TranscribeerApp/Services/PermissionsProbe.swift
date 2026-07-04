import AVFoundation
import ApplicationServices
import CoreGraphics
import Foundation
import os

private let logger = Logger(subsystem: "com.transcribeer", category: "permissions-probe")

/// Polls TCC and accessibility permission state for the onboarding wizard
/// and any future Settings health cards.
///
/// All state is read on the main actor so SwiftUI views can observe it directly.
/// The poll loop runs every 500 ms while active; call `stopPolling()` when the
/// view that owns this probe disappears.
@Observable @MainActor
final class PermissionsProbe {
    // MARK: - Public state

    private(set) var microphoneGranted: Bool = false
    private(set) var screenRecordingGranted: Bool = false
    private(set) var accessibilityGranted: Bool = false

    // MARK: - Private

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func startPolling() {
        guard pollTask == nil else { return }
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }
                await MainActor.run { self?.refresh() }
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Performs one immediate check of all permissions and updates published state.
    func refresh() {
        microphoneGranted = checkMicrophone()
        screenRecordingGranted = checkScreenRecording()
        accessibilityGranted = checkAccessibility()
        logger.debug(
            "permissions mic=\(self.microphoneGranted, privacy: .public) screen=\(self.screenRecordingGranted, privacy: .public) ax=\(self.accessibilityGranted, privacy: .public)"
        )
    }

    // MARK: - Private checks

    private func checkMicrophone() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// `CGPreflightScreenCaptureAccess()` returns true when the process already
    /// has screen-capture permission — without showing a consent dialog.
    private func checkScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// `AXIsProcessTrustedWithOptions(nil)` returns the current trusted state
    /// without prompting or opening the System Settings pane.
    private func checkAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(nil as CFDictionary?)
    }
}
