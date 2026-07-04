import SwiftUI
import TranscribeerCore

// MARK: - Step enum

enum OnboardingStep: CaseIterable {
    case welcome
    case language
    case models
    case permissions
    case ready
}

// MARK: - Root sheet

/// Root view for the first-run setup wizard.
///
/// Presented as a `.sheet` over the app's main window. Owns step routing and
/// the Back/Continue bottom bar. Each page is a separate view under
/// `Views/Onboarding/`.
struct OnboardingSheet: View {
    @Bindable var state: OnboardingState
    @Environment(\.dismiss) private var dismiss

    @State private var step: OnboardingStep = .welcome
    @State private var downloader = HebrewModelDownloader()
    @State private var probe = PermissionsProbe()

    var body: some View {
        VStack(spacing: 0) {
            // Skip link pinned to the top-right corner
            HStack {
                Spacer()
                Button("Skip setup") {
                    state.markCompleted()
                    dismiss()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding([.top, .trailing], 16)
            }

            // Page content
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Step indicator
            stepDots
                .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .frame(width: 560)
    }

    // MARK: - Page routing

    @ViewBuilder
    private var pageContent: some View {
        switch step {
        case .welcome:
            OnboardingWelcomeView(onGetStarted: { advance() })
        case .language:
            OnboardingLanguageView(state: state)
        case .models:
            OnboardingModelsView(state: state, downloader: downloader)
        case .permissions:
            OnboardingPermissionsView(probe: probe)
        case .ready:
            OnboardingReadyView(state: state, dismiss: { dismiss() })
        }
    }

    // MARK: - Step dots

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.self) { s in
                Circle()
                    .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            if step != .welcome {
                Button("Back") { retreat() }
                    .buttonStyle(.borderless)
            }
            Spacer()
            if step != .ready {
                Button(continueLabel) { advance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canContinue)
                    .keyboardShortcut(.return)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.bar)
    }

    private var continueLabel: String {
        switch step {
        case .models: "Continue in background"
        default: "Continue"
        }
    }

    private var canContinue: Bool {
        switch step {
        case .language: !state.selectedLanguages.isEmpty
        default: true
        }
    }

    // MARK: - Navigation

    private func advance() {
        let all = OnboardingStep.allCases
        guard let idx = all.firstIndex(of: step), idx + 1 < all.count else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            step = all[idx + 1]
        }
    }

    private func retreat() {
        let all = OnboardingStep.allCases
        guard let idx = all.firstIndex(of: step), idx > 0 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            step = all[idx - 1]
        }
    }
}
