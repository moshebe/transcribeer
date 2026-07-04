import Foundation
import Testing
@testable import TranscribeerApp

struct OnboardingStateTests {
    // MARK: - shouldShowOnboarding

    @Test("Fresh install: hasCompletedOnboarding=false → should show onboarding")
    func freshInstallShowsOnboarding() {
        let state = makeState(completed: false, version: "")
        #expect(state.shouldShowOnboarding == true)
    }

    @Test("Completed with current version: should not show onboarding")
    func completedCurrentVersionHidesOnboarding() {
        let state = makeState(completed: true, version: OnboardingState.currentVersion)
        #expect(state.shouldShowOnboarding == false)
    }

    @Test("Completed with old version: should re-show onboarding")
    func completedOldVersionShowsOnboarding() {
        let state = makeState(completed: true, version: "0.9")
        #expect(state.shouldShowOnboarding == true)
    }

    @Test("Not completed with current version: should show onboarding")
    func notCompletedCurrentVersionShowsOnboarding() {
        let state = makeState(completed: false, version: OnboardingState.currentVersion)
        #expect(state.shouldShowOnboarding == true)
    }

    // MARK: - markCompleted

    @Test("markCompleted sets hasCompletedOnboarding and lastOnboardingVersion")
    func markCompletedSetsFlags() {
        let state = makeState(completed: false, version: "")
        state.markCompleted()
        #expect(state.hasCompletedOnboarding == true)
        #expect(state.lastOnboardingVersion == OnboardingState.currentVersion)
        #expect(state.shouldShowOnboarding == false)
    }

    // MARK: - resetForRerun

    @Test("resetForRerun clears hasCompletedOnboarding so wizard shows again")
    func resetForRerunClearsCompletion() {
        let state = makeState(completed: true, version: OnboardingState.currentVersion)
        #expect(state.shouldShowOnboarding == false)
        state.resetForRerun()
        #expect(state.hasCompletedOnboarding == false)
        #expect(state.shouldShowOnboarding == true)
    }

    @Test("resetForRerun restores default selectedLanguages")
    func resetForRerunRestoresDefaultLanguages() {
        let state = makeState(completed: true, version: OnboardingState.currentVersion)
        state.selectedLanguages = ["he"]
        state.resetForRerun()
        #expect(state.selectedLanguages == ["en", "he"])
    }

    // MARK: - selectedLanguages

    @Test("Default selectedLanguages includes both en and he")
    func defaultLanguagesAreBoth() {
        let state = makeState(completed: false, version: "")
        #expect(state.selectedLanguages.contains("en"))
        #expect(state.selectedLanguages.contains("he"))
    }

    // MARK: - Helpers

    /// Creates a standalone `OnboardingState` backed by an isolated `UserDefaults` suite
    /// so tests don't pollute the real defaults or each other.
    private func makeState(completed: Bool, version: String) -> OnboardingState {
        let suiteName = "com.transcribeer.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(completed, forKey: "hasCompletedOnboarding")
        defaults?.set(version, forKey: "lastOnboardingVersion")
        return OnboardingState(defaults: defaults ?? .standard)
    }
}
