import SwiftUI

struct OnboardingLanguageView: View {
    @Bindable var state: OnboardingState

    var body: some View {
        VStack(spacing: 0) {
            header

            Form {
                Section {
                    languageRow(
                        code: "en",
                        label: "English",
                        icon: "flag.us.circle"
                    )
                    languageRow(
                        code: "he",
                        label: "Hebrew (עברית)",
                        icon: "globe"
                    )
                } footer: {
                    Text("You can change this later in Settings \u{2192} Transcription.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - Subviews

    private var header: some View {
        VStack(spacing: 6) {
            Text("Choose your languages")
                .font(.title2)
                .fontWeight(.semibold)
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func languageRow(code: String, label: String, icon: String) -> some View {
        let isOn = Binding<Bool>(
            get: { state.selectedLanguages.contains(code) },
            set: { enabled in
                if enabled {
                    state.selectedLanguages.insert(code)
                } else {
                    state.selectedLanguages.remove(code)
                }
            }
        )
        return Toggle(isOn: isOn) {
            Label(label, systemImage: icon)
        }
    }
}
