import Foundation

/// Persists onboarding completion state and carries transient wizard selections.
///
/// Backed by `UserDefaults.standard`. Observed by any view that needs to know
/// whether the wizard should be presented or has already been completed.
@Observable final class OnboardingState {
    // MARK: - Constants

    static let currentVersion = "1.0"

    private enum Keys {
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let lastOnboardingVersion = "lastOnboardingVersion"
    }

    // MARK: - Private storage

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - Persisted state

    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    var lastOnboardingVersion: String {
        didSet { defaults.set(lastOnboardingVersion, forKey: Keys.lastOnboardingVersion) }
    }

    // MARK: - Transient wizard state

    /// Languages selected on the Language page. Only lives for the duration of the wizard run.
    var selectedLanguages: Set<String> = ["en", "he"]

    // MARK: - Derived

    var shouldShowOnboarding: Bool {
        !hasCompletedOnboarding || lastOnboardingVersion != Self.currentVersion
    }

    // MARK: - Init

    /// Creates an `OnboardingState` backed by `UserDefaults.standard`.
    convenience init() {
        self.init(defaults: .standard)
    }

    /// Creates an `OnboardingState` backed by the supplied `UserDefaults`.
    /// Inject a custom suite in tests to avoid polluting the real defaults.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        self.lastOnboardingVersion = defaults.string(forKey: Keys.lastOnboardingVersion) ?? ""
    }

    // MARK: - Actions

    func markCompleted() {
        hasCompletedOnboarding = true
        lastOnboardingVersion = Self.currentVersion
    }

    func resetForRerun() {
        hasCompletedOnboarding = false
        selectedLanguages = ["en", "he"]
    }
}
