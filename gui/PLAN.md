# Transcribee GUI — Implementation Plan

macOS-only menubar app wrapping the `transcribee` CLI.
Built with SwiftUI (`MenuBarExtra`), macOS 13+, no Dock icon.

---

## Architecture

```
gui/
  Package.swift
  Sources/TranscribeeMenuBar/
    TranscribeeMenuBarApp.swift   ← @main, MenuBarExtra, wires everything
    MenuBarView.swift             ← SwiftUI menu content, observes AppState
    TranscribeeRunner.swift       ← Process management + state machine
    NotificationManager.swift     ← UNUserNotificationCenter wrapper
```

### Shared contract (types all files must agree on)

```swift
// AppState — the single source of truth, published by TranscribeeRunner
enum AppState {
    case idle
    case recording            // capture running
    case transcribing         // step 2/3
    case summarizing          // step 3/3
    case done(sessionPath: String)
    case error(String)
}
```

### Component interfaces

**`TranscribeeRunner: ObservableObject`**
```swift
@Published var state: AppState = .idle
func start()   // launches transcribee run, changes state → .recording
func stop()    // sends SIGINT, state changes happen via output parsing
```
Output parsing (reads stderr line by line):
- `"Step 2/3"` → `.transcribing`
- `"Step 3/3"` → `.summarizing`
- `"Session:"` + path → `.done(sessionPath:)`
- `"Error:"` / `"failed"` → `.error(...)`

Binary discovery order:
1. `~/.local/bin/transcribee`
2. `/usr/local/bin/transcribee`
3. Falls back to `.error("transcribee not found — run install.sh")`

**`NotificationManager`**
```swift
static func requestPermission()
static func notify(title: String, body: String)
```
Called by `TranscribeeRunner` on `.done` and `.error`.

**`MenuBarView`**
Observes `TranscribeeRunner` via `@EnvironmentObject`.
Menu items:
- `idle`: "Start Recording" (enabled), "Quit"
- `recording`: "● Recording… (tap to stop)" (enabled), "Quit"
- `transcribing`/`summarizing`: "⏳ Processing…" (disabled), "Quit"
- `done`: "✓ Last session" (opens Finder), "Start Recording", "Quit"
- `error`: "⚠ Error" (shows message), "Start Recording", "Quit"

---

## Chunks

### Chunk 1 — Skeleton ✅ (prerequisite for all)
**Files:** `Package.swift`, `TranscribeeMenuBarApp.swift`, stub `MenuBarView.swift`

- `Package.swift` with `.executableTarget` + `@main` SwiftUI App
- `MenuBarExtra("Transcribee", systemImage: "mic")` with static menu
- `.menuBarExtraStyle(.menu)` — no popover, pure menu
- `NSApp.setActivationPolicy(.accessory)` — no Dock icon
- Build: `cd gui && swift build -c release`
- Install helper in `install.sh`: copy `.build/release/TranscribeeMenuBar` → `/Applications/Transcribee.app` (stub .app bundle)

> **Agent can start immediately. No dependencies.**

---

### Chunk 2 — Subprocess bridge (`TranscribeeRunner.swift`)
**Files:** `TranscribeeRunner.swift`

- `Process` + `Pipe` for stdout/stderr
- Async line reading on background queue, publish state on main queue
- `start()`: build args `["run"]`, launch process
- `stop()`: `process.interrupt()` (sends SIGINT)
- Parse stderr per the contract above
- Process exit code: 0 = success (→ `.done`), non-zero = `.error`
- On `.done`: extract session path from `"Session: <path>"` line

> **Can be written without Chunk 1 complete — pure Swift logic, no UI imports.**
> Depends only on the `AppState` enum defined above.

---

### Chunk 3 — Notifications (`NotificationManager.swift`)
**Files:** `NotificationManager.swift`

- Request permission on first launch (store in `UserDefaults`)
- `notify(title:body:)` posts a `UNMutableNotificationContent` with 0-second trigger
- Called from `TranscribeeRunner` in `didSet` of `state` for `.done` and `.error`

> **Fully independent. Can be written without Chunk 1 or 2.**
> No dependencies beyond `UserNotifications` framework.

---

### Chunk 4 — App detection (Phase 2)
**Files:** `AppWatcher.swift`

- `NSWorkspace.shared.notificationCenter` observers:
  - `NSWorkspace.didLaunchApplicationNotification`
  - `NSWorkspace.didTerminateApplicationNotification`
- Default watch list: `["us.zoom.xos", "com.microsoft.teams2", "com.loom.desktop"]`
- On launch: post a `UNNotification` with actions "Start Recording" / "Ignore"
  - `UNNotificationAction` response → `TranscribeeRunner.start()`
- On terminate (if recording): `TranscribeeRunner.stop()`
- Persist "don't ask" per bundle ID in `UserDefaults`

> **Depends on Chunks 1–3 being merged.**

---

### Chunk 5 — Session history (Phase 3)
**Files:** `SessionHistoryView.swift`, `SessionStore.swift`

- `SessionStore`: reads `~/.transcribee/sessions/`, sorted by `st_ctime`
- Each session: date, WAV size → estimated duration, transcript preview (first 80 chars)
- Label support: read/write `.label` sidecar file per session dir
- UI: `MenuBarExtra` with `.window` style → shows a SwiftUI list in a popover
- Double-click session → `NSWorkspace.open(sessionURL)`

> **Depends on Chunks 1–3 being merged. Independent of Chunk 4.**

---

### Chunk 6 — Export integrations (Phase 4)
**Files:** `ExportManager.swift`, `NotionExporter.swift`, `GoogleDocsExporter.swift`

- Notion: `POST /v1/pages` with transcript as blocks
  - API key stored in Keychain (`kSecClass = kSecClassGenericPassword`)
- Google Docs: OAuth2 PKCE flow → `POST /v1/documents/{id}/batchUpdate`
- Menu item per session: "Export → Notion / Google Docs"

> **Depends on Chunk 5 (session model). Notion before Google Docs.**

---

## Build & Install

```bash
cd gui
swift build -c release
# binary at: .build/release/TranscribeeMenuBar
```

`install.sh` will handle bundling into a minimal `.app` and copying to `/Applications`.
No Xcode required — pure SPM.

---

## Open questions (resolve before Chunk 1 commit)

1. **App signing**: ad-hoc (`codesign -s -`) is fine for personal use. Developer ID needed for distribution.
2. **Login item**: auto-start via `SMAppService.mainApp.register()` (macOS 13+)? Default off, toggle in menu.
3. **Settings**: `~/.transcribee/gui.toml` or `UserDefaults`? Start with `UserDefaults` (simpler), migrate later.
