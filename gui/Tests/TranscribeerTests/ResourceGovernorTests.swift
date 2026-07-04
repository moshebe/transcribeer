import Foundation
import Testing
@testable import TranscribeerApp

// All tests run on the main actor because ResourceGovernor is @MainActor.
@MainActor
struct ResourceGovernorTests {
    // MARK: - Helpers

    /// Build a governor with fully-injected providers so no real hardware is
    /// consulted during tests.
    private func makeGovernor(
        thermal: ProcessInfo.ThermalState = .nominal,
        lowPower: Bool = false,
        chipGen: ChipGeneration = .m3,
        chipTier: ChipTier = .pro,
        onBattery: Bool = false
    ) -> ResourceGovernor {
        let info = ChipInfo(brand: "Test Chip", generation: chipGen, tier: chipTier)
        return ResourceGovernor(
            thermalStateProvider: { thermal },
            lowPowerModeProvider: { lowPower },
            chipInfoProvider: { info },
            powerSourceProvider: { onBattery }
        )
    }

    // MARK: - Thermal state policy

    @Test("Thermal critical → allowParallel false, maxConcurrency 1")
    func thermalCritical() {
        let governor = makeGovernor(thermal: .critical)
        let budget = governor.currentBudget()
        #expect(budget.allowParallel == false)
        #expect(budget.maxConcurrency == 1)
    }

    @Test("Thermal serious → maxConcurrency 1, allowParallel true")
    func thermalSerious() {
        let governor = makeGovernor(thermal: .serious)
        let budget = governor.currentBudget()
        #expect(budget.maxConcurrency == 1)
        #expect(budget.allowParallel == true)
    }

    // MARK: - Low power mode

    @Test("Low power mode → maxConcurrency 1")
    func lowPowerMode() {
        let governor = makeGovernor(lowPower: true)
        let budget = governor.currentBudget()
        #expect(budget.maxConcurrency == 1)
    }

    // MARK: - Chip tier policy

    @Test("Air chip on AC with nominal thermals → maxConcurrency 1")
    func airChipOnACNominal() {
        let governor = makeGovernor(chipGen: .m2, chipTier: .air, onBattery: false)
        let budget = governor.currentBudget()
        #expect(budget.maxConcurrency == 1)
    }

    @Test("Pro chip on AC with nominal thermals, no low power → maxConcurrency 2")
    func proChipOnACNominal() {
        let governor = makeGovernor(
            thermal: .nominal,
            lowPower: false,
            chipGen: .m3,
            chipTier: .pro,
            onBattery: false
        )
        let budget = governor.currentBudget()
        #expect(budget.maxConcurrency == 2)
        #expect(budget.allowParallel == true)
    }

    @Test("Max chip on AC with nominal thermals → maxConcurrency 3")
    func maxChipOnACNominal() {
        let governor = makeGovernor(
            thermal: .nominal,
            lowPower: false,
            chipGen: .m2,
            chipTier: .max,
            onBattery: false
        )
        let budget = governor.currentBudget()
        #expect(budget.maxConcurrency == 3)
        #expect(budget.allowParallel == true)
    }

    @Test("Ultra chip on AC with nominal thermals → maxConcurrency 3")
    func ultraChipOnACNominal() {
        let governor = makeGovernor(
            thermal: .nominal,
            lowPower: false,
            chipGen: .m2,
            chipTier: .ultra,
            onBattery: false
        )
        let budget = governor.currentBudget()
        #expect(budget.maxConcurrency == 3)
    }

    // MARK: - Memory pressure overrides

    @Test("Memory pressure warning within 60s → maxConcurrency floored to 1")
    func memoryWarningRecent() {
        let governor = makeGovernor(
            thermal: .nominal,
            chipGen: .m3,
            chipTier: .max,
            onBattery: false
        )
        governor.simulateMemoryPressure(level: .warning, at: Date())

        let budget = governor.currentBudget()
        #expect(budget.maxConcurrency == 1)
    }

    @Test("Memory pressure critical within 60s → allowParallel false")
    func memoryCriticalRecent() {
        let governor = makeGovernor(
            thermal: .nominal,
            chipGen: .m3,
            chipTier: .max,
            onBattery: false
        )
        governor.simulateMemoryPressure(level: .critical, at: Date())

        let budget = governor.currentBudget()
        #expect(budget.allowParallel == false)
    }

    @Test("Memory pressure event older than 60s → no longer influences budget")
    func memoryPressureExpired() {
        let governor = makeGovernor(
            thermal: .nominal,
            chipGen: .m3,
            chipTier: .max,
            onBattery: false
        )
        // 61 seconds ago → outside the 60-second window
        governor.simulateMemoryPressure(
            level: .critical,
            at: Date().addingTimeInterval(-61)
        )

        let budget = governor.currentBudget()
        // Max chip on AC nominal without active pressure → should be 3 / parallel
        #expect(budget.maxConcurrency == 3)
        #expect(budget.allowParallel == true)
    }

    // MARK: - ANE and idle unload constants

    @Test("allowANE is always true")
    func allowANEAlwaysTrue() {
        // Check across several scenarios
        let scenarios: [(ProcessInfo.ThermalState, Bool)] = [
            (.critical, false),
            (.nominal, false),
            (.nominal, true),
        ]
        for (thermal, lowPower) in scenarios {
            let governor = makeGovernor(thermal: thermal, lowPower: lowPower)
            #expect(governor.currentBudget().allowANE == true)
        }
    }

    @Test("idleUnloadMinutes is always 10")
    func idleUnloadMinutesAlwaysTen() {
        let governor = makeGovernor()
        #expect(governor.currentBudget().idleUnloadMinutes == 10)
    }
}
