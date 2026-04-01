import SwiftUI

// LSUIElement = YES must be set in Info.plist to suppress the Dock icon.
// With pure SPM (no Xcode project), add an Info.plist resource to the target
// and set LSUIElement to YES there.

@main
struct TranscribeeMenuBarApp: App {
    @StateObject private var runner = TranscribeeRunner()

    var body: some Scene {
        MenuBarExtra("Transcribee", systemImage: "mic") {
            MenuBarView()
                .environmentObject(runner)
                .onAppear { NotificationManager.requestPermission() }
        }
        .menuBarExtraStyle(.menu)
    }
}
