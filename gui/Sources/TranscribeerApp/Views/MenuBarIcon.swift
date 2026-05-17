import AppKit
import SwiftUI

/// Menu bar icon that overlays a red dot on the mic while recording.
///
/// Two independent macOS/SwiftUI quirks shape this view:
///
/// 1. `MenuBarExtra(style: .menu)` does not re-render its label when an
///    `@Observable` model's properties change — neither reading in the Scene
///    body nor reading in this view's body reliably triggers a refresh. We
///    work around that by mirroring `runner.state` into local `@State` via a
///    polling task. Local `@State` mutations *do* refresh the menu bar.
///
/// 2. `MenuBarExtra`'s label only honors plain `Image`/`Text`/`Label`; any
///    composite SwiftUI view (`ZStack`, overlays, `foregroundStyle`, shape
///    fills) is stripped before it reaches the menu bar. That is why the
///    obvious `ZStack { Image(systemName: "mic"); Circle().fill(.red) }`
///    approach silently renders only the mic. We pre-composite the icon into
///    an `NSImage` in `RecordingIndicatorRenderer` and pass that via
///    `Image(nsImage:)` instead.
///
/// When the running bundle identifier ends in `.dev` a small orange "D" is
/// baked into the composited image so a dev build sitting alongside a
/// production install can be told apart at a glance.
struct MenuBarIcon: View {
    let runner: PipelineRunner
    @State private var displayState: AppState = .idle
    @State private var appearanceTick = 0

    /// Distributed notification macOS posts when the system theme flips.
    /// Re-render so the manually tinted mic body tracks light/dark changes.
    private let themeChanges = DistributedNotificationCenter.default().publisher(
        for: Notification.Name("AppleInterfaceThemeChangedNotification"),
    )

    var body: some View {
        // `.id(appearanceTick)` forces a rebuild when the system theme flips
        // so the manually tinted mic body tracks light/dark changes.
        Image(nsImage: RecordingIndicatorRenderer.menuBarImage(
            state: displayState,
            isDevBuild: Self.isDevBuild,
        ))
        .id(appearanceTick)
        .task(id: ObjectIdentifier(runner)) {
            while !Task.isCancelled {
                let current = runner.state
                if current != displayState {
                    displayState = current
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        .onReceive(themeChanges) { _ in appearanceTick &+= 1 }
    }

    private static let isDevBuild: Bool = {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
    }()
}
