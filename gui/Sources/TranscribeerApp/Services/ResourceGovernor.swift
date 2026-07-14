import Foundation
import IOKit.ps
import os.log
import TranscribeerCore

private let logger = Logger(subsystem: "com.transcribeer", category: "resource-governor")

// MARK: - ResourceGovernor

/// Observes system-resource signals and derives a `TranscriptionBudget` that
/// ChunkedTranscriber and TranscriptionService can consume without knowing the
/// underlying sensor details.
///
/// All mutable state lives on the `@MainActor` so SwiftUI views can bind to it
/// directly. Background sensing (notifications, dispatch source, timer) hops
/// back to `@MainActor` before mutating state.
@Observable
@MainActor
final class ResourceGovernor {
    // MARK: - Nested types

    enum MemoryPressureLevel { case warning, critical }

    // MARK: - Observable state

    private(set) var thermalState: ProcessInfo.ThermalState
    private(set) var isLowPowerMode: Bool
    private(set) var chipInfo: ChipInfo
    private(set) var isOnBattery: Bool
    private(set) var lastMemoryPressureEvent: Date?
    private(set) var lastMemoryPressureLevel: MemoryPressureLevel?

    /// When `true`, `currentBudget()` always returns the chip-tier maximum and
    /// the `ResourceStatusBanner` is suppressed. Set by the user via Settings.
    var isThrottlingDisabled: Bool = false

    // MARK: - Providers (injectable for testing)

    private let thermalStateProvider: @Sendable () -> ProcessInfo.ThermalState
    private let lowPowerModeProvider: @Sendable () -> Bool
    private let chipInfoProvider: @Sendable () -> ChipInfo
    private let powerSourceProvider: @Sendable () -> Bool

    // MARK: - Internal sensing handles
    // Stored as nonisolated(unsafe) so deinit (which is nonisolated) can
    // cancel/invalidate them without a concurrency error.

    nonisolated(unsafe) private var thermalObserver: NSObjectProtocol?
    nonisolated(unsafe) private var powerModeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var memoryPressureSource: DispatchSourceMemoryPressure?
    nonisolated(unsafe) private var powerPollTimer: Timer?

    // MARK: - Init

    init(
        thermalStateProvider: @escaping @Sendable () -> ProcessInfo.ThermalState = {
            ProcessInfo.processInfo.thermalState
        },
        lowPowerModeProvider: @escaping @Sendable () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        },
        chipInfoProvider: @escaping @Sendable () -> ChipInfo = {
            ChipClassifier.detect()
        },
        powerSourceProvider: @escaping @Sendable () -> Bool = {
            ResourceGovernor.isOnBatteryPower()
        }
    ) {
        self.thermalStateProvider = thermalStateProvider
        self.lowPowerModeProvider = lowPowerModeProvider
        self.chipInfoProvider = chipInfoProvider
        self.powerSourceProvider = powerSourceProvider

        // Seed initial values synchronously before wiring up observers.
        thermalState = thermalStateProvider()
        isLowPowerMode = lowPowerModeProvider()
        chipInfo = chipInfoProvider()
        isOnBattery = powerSourceProvider()

        wireThermalObserver()
        wirePowerModeObserver()
        wireMemoryPressureSource()
        wirePowerPollTimer()
    }

    deinit {
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        if let powerModeObserver {
            NotificationCenter.default.removeObserver(powerModeObserver)
        }
        memoryPressureSource?.cancel()
        powerPollTimer?.invalidate()
    }

    // MARK: - Budget computation

    /// Derive the current operational budget from all observed signals.
    func currentBudget() -> TranscriptionBudget {
        // When the user has opted out of throttling, return the chip-tier maximum
        // and skip all thermal / power / memory checks.
        if isThrottlingDisabled {
            let maxConcurrency: Int
            switch chipInfo.tier {
            case .max, .ultra: maxConcurrency = 3
            case .pro:         maxConcurrency = 2
            default:           maxConcurrency = 1
            }
            return TranscriptionBudget(
                maxConcurrency: maxConcurrency,
                allowANE: true,
                allowParallel: true,
                idleUnloadMinutes: 10
            )
        }

        var maxConcurrency: Int
        var allowParallel: Bool

        // Policy table — evaluated top-to-bottom, first match wins.
        switch thermalState {
        case .critical:
            maxConcurrency = 1
            allowParallel = false
        case .serious:
            maxConcurrency = 1
            allowParallel = true
        default:
            if isLowPowerMode {
                maxConcurrency = 1
                allowParallel = true
            } else if isOnBattery && thermalState.rawValue >= ProcessInfo.ThermalState.fair.rawValue {
                maxConcurrency = 1
                allowParallel = true
            } else if chipInfo.tier == .air {
                maxConcurrency = 1
                allowParallel = true
            } else if chipInfo.tier == .pro && !isOnBattery && thermalState == .nominal {
                maxConcurrency = 2
                allowParallel = true
            } else if (chipInfo.tier == .max || chipInfo.tier == .ultra)
                        && !isOnBattery && thermalState == .nominal {
                maxConcurrency = 3
                allowParallel = true
            } else {
                // Default: conservative but parallel
                maxConcurrency = 1
                allowParallel = true
            }
        }

        // Memory-pressure overrides (applied after the primary policy).
        if let level = lastMemoryPressureLevel,
           let event = lastMemoryPressureEvent,
           Date().timeIntervalSince(event) <= 60 {
            switch level {
            case .warning:
                maxConcurrency = min(maxConcurrency, 1)
            case .critical:
                allowParallel = false
            }
        }

        return TranscriptionBudget(
            maxConcurrency: maxConcurrency,
            allowANE: true,
            allowParallel: allowParallel,
            idleUnloadMinutes: 10
        )
    }

    // MARK: - Power source detection

    /// Returns `true` when the Mac is running on battery power.
    /// `nonisolated` so it can be used as the default value for
    /// `powerSourceProvider` in the initialiser without an actor hop.
    nonisolated static func isOnBatteryPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty else {
            // Can't determine → assume AC (safe default)
            return false
        }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  let state = desc[kIOPSPowerSourceStateKey] as? String else {
                continue
            }
            if state == kIOPSBatteryPowerValue {
                return true
            }
        }
        return false
    }

    // MARK: - Testing support

    /// Seed memory pressure state without going through the real dispatch source.
    /// Used exclusively by unit tests via `@testable import`.
    func simulateMemoryPressure(level: MemoryPressureLevel, at date: Date = Date()) {
        lastMemoryPressureEvent = date
        lastMemoryPressureLevel = level
    }

    // MARK: - Private wiring

    private func wireThermalObserver() {
        let provider = thermalStateProvider
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            let newState = provider()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.thermalState = newState
                logger.info("thermal state changed: \(String(describing: newState))")
            }
        }
    }

    private func wirePowerModeObserver() {
        let provider = lowPowerModeProvider
        powerModeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            let newMode = provider()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLowPowerMode = newMode
                logger.info("low power mode changed: \(newMode)")
            }
        }
    }

    private func wireMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard self != nil else { return }
            let data = source.data
            let level: MemoryPressureLevel = data.contains(.critical) ? .critical : .warning
            let now = Date()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastMemoryPressureEvent = now
                self.lastMemoryPressureLevel = level
                logger.warning("memory pressure: \(String(describing: level))")
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func wirePowerPollTimer() {
        let provider = powerSourceProvider
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard self != nil else { return }
            let onBattery = provider()
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isOnBattery != onBattery {
                    self.isOnBattery = onBattery
                    logger.info("power source changed: onBattery=\(onBattery)")
                }
            }
        }
        // Allow timer to fire even when the run loop is in a tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        powerPollTimer = timer
    }
}
