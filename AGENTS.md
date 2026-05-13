# Transcribeer — Agent Coding Guide

Repo-specific conventions. These layer on top of global defaults; when they conflict, these win.

## Layout

- `gui/` — SwiftUI menubar app (SPM, `TranscribeerApp` target). **Primary code surface.**
- `capture/` — Core Audio process tap + AVAudioEngine audio recorder (CaptureCore library)
- `tests/e2e/` — Python end-to-end tests (pytest)
- `obsidian-plugin/` — TS plugin (esbuild, vanilla `main.ts`)
- `docs/`, `assets/`, `test-samples/` — supporting material

Config/state: `~/.transcribeer/` (config.toml, prompts/, models/, sessions/, bin/, log/).

## Stack

- macOS 15+, Apple Silicon only
- Swift 6 (tools-version 6.0), `swiftLanguageMode(.v5)` for `gui` target
- SPM dependencies: `TOMLDecoder`, `WhisperKit`, `SpeakerKit`, `LLM`, `HighlightedTextEditor`
- Audio capture: Core Audio process tap (`AudioHardwareCreateProcessTap`) + AVAudioEngine, **not** ScreenCaptureKit/SCStream
- API keys: macOS Keychain via `KeychainHelper` — **never** config file, **never** env var in code paths intended for UI storage

## Swift conventions

Follow `.swiftlint.yml` as ground truth. Run `make lint` before committing.

### Hard rules (from swiftlint config)

- **No force unwrap** (`!`), **no force cast**, **no force try** — errors, not warnings
- **No implicitly unwrapped optionals** except `@IBOutlet`
- Line length ≤ 120 (error at 160); file ≤ 600 lines; function body ≤ 80
- Cyclomatic complexity ≤ 12
- Mandatory trailing commas in multi-line literals
- `implicit_return`, `redundant_type_annotation`, `redundant_nil_coalescing` enforced

### Style patterns actually used in this codebase

- **Switch expressions** for simple mapping (Swift 5.9+): `case .idle: ""` not `case .idle: return ""`
- **`@Observable`** for view models and services (`PipelineRunner`, `ModelCatalogService`, `ZoomWatcher`)
- **`@State private var runner = PipelineRunner()`** in app/view root — not `@StateObject`
- **Caseless `enum` for namespaces** (`PromptProfileManager`, `ShellEnvironment`, `KeychainHelper`, `SessionManager`, `ConfigManager`)
- **Nested types** for scoped concepts (`ProfileError` nested in `PromptProfileManager`, `Probe` inside `OllamaHostStatus`)
- **`// MARK: -`** to section files
- `guard` with early return for preconditions
- `if let value` shorthand (no `= value`)
- Key paths over `{ $0.x }` where possible (`.map(\.id)`)
- `@MainActor` for anything touching `NSApp`/UI state; wrap background hops in `Task { @MainActor in ... }`

### Errors

- Domain-specific enums conforming to `LocalizedError` (see `PromptProfileManager.ProfileError`)
- `errorDescription` returns user-facing strings — these surface directly in alerts
- `try?` only when discarding is intentional; otherwise `do/catch` with `os.log`

### Logging

Every service gets its own `Logger`:

```swift
private let logger = Logger(subsystem: "com.transcribeer", category: "<service>")
```

Log errors with `.localizedDescription`, not the full `error` object.

### SwiftUI views

- One view per file; private helper views in same file with `// MARK: -`
- Extract sub-views (`ModelPickerRow`, `StatusIcon`, `OllamaHostStatus`) — don't inline complex `ZStack`s
- `@Binding` for two-way config state, `@State` for ephemeral view state
- `.task { }` for async view-lifecycle work; `.task(id:)` for debounced probes
- Auto-save via debounced `Task.sleep` + cancellation (see `PromptsSettingsView.scheduleSave`, `SessionDetailView` notes)
- Alerts use a derived `Binding<Bool>` off the optional `errorMessage` state

### Models / state

- `enum AppState: Equatable` — single source of truth for pipeline state, with computed `isRecording`/`isBusy`/`statusText`
- Session metadata on disk is the canonical store; `Session`/`SessionDetail` are views over it
- `ConfigManager.load()`/`save()` — TOML round-trip, called explicitly after mutations

## Testing

- **Swift Testing** framework (`import Testing`, `@Test`, `#expect`) — not XCTest
- Table-driven tests via `arguments:` (see `AppStateTests`)
- `@testable import TranscribeerApp`
- Run: `cd gui && swift test` (or `swift test --filter <Name>`)
- Pure-logic tests only in gui — no UI automation, no network

E2E:
- `cd tests/e2e && uv run pytest` (requires API keys for LLM tests)

## Build & verify

```bash
cd gui
swift build            # compile check — do this after any Swift change
swift test             # run Swift Testing suites
make lint              # swiftlint (from repo root)
make lint-strict       # CI-equivalent (warnings → errors)
```

Full app bundle:
```bash
make build-dev         # produces gui/.build/Transcribeer.app
make gui               # build + launch
```

## Workflow


- After Swift changes touching `gui/`: `swift build` + `make lint` before reporting done
- Keep SwiftUI state changes minimal — don't convert `@State` ↔ `@StateObject` ↔ `@Observable` without reason
- When adding a new pipeline stage, extend `AppState` enum + update exhaustive switches (compiler will list them)
- Keychain/API-key flow is sensitive — mirror existing `KeychainHelper.setAPIKey` / `getAPIKey` calls; don't invent new storage

## What not to do

- Don't add `ObservableObject`/`@Published` — project is fully on `@Observable`
- Don't introduce new third-party SPM deps without checking `Package.swift` — keep the list in `CONTRIBUTING.md` honest
- Don't widen access (`internal` → `public`) in gui code — it's a single executable target
- Don't spawn unstructured `Task { }` when `async let` or `.task { }` fits
- Don't log raw API keys, transcripts, or session contents — use path references
- Don't reach across layers: `Views/` calls `Services/`, `Services/` own I/O. Models are passive.
- Don't force-unwrap to silence optionals — swiftlint will fail the build
- Don't reintroduce `SCStream` / ScreenCaptureKit for audio capture — the capture layer uses Core Audio process taps exclusively

## Commit / PR

- Conventional commits (`feat:`, `fix:`, `refactor:`, `chore:`, `docs:`)
- One concern per PR
- Include `swift test` + `make lint` results in PR description when touching gui
