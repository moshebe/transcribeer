import SwiftUI

struct OnboardingReadyView: View {
    @Bindable var state: OnboardingState
    let dismiss: () -> Void

    private let nextSteps: [String] = [
        "Click the menu bar icon to start a recording",
        "Explore Settings to configure the pipeline",
        "Change models anytime in Settings \u{2192} Transcription",
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .frame(width: 72, height: 72)
                .foregroundStyle(.green)

            VStack(spacing: 10) {
                Text("You're all set")
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                Text("Here's what to do next:")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(nextSteps, id: \.self) { step in
                    HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(Color.accentColor)
                            .font(.body)
                        Text(step)
                            .font(.body)
                    }
                }
            }
            .frame(maxWidth: 380, alignment: .leading)

            Button("Done") {
                state.markCompleted()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return)

            Spacer()
        }
        .padding(.horizontal, 40)
    }
}
