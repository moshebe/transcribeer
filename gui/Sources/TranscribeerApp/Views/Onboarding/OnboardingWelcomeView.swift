import SwiftUI

struct OnboardingWelcomeView: View {
    let onGetStarted: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            appLogo

            VStack(spacing: 10) {
                Text("Welcome to Transcribeer")
                    .font(.largeTitle)
                    .fontWeight(.semibold)

                Text("Record, transcribe, and summarize meetings — entirely on your Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Button("Get Started") {
                onGetStarted()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return)

            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: - Logo

    @ViewBuilder
    private var appLogo: some View {
        if let nsImage = NSImage(named: "AppIcon") {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: 96, height: 96)
        } else {
            Image(systemName: "mic.circle.fill")
                .resizable()
                .frame(width: 96, height: 96)
                .foregroundStyle(Color.accentColor)
        }
    }
}
