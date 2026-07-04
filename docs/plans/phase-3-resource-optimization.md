# Phase 3 — Resource Optimization

Goals: the laptop must never freeze. Transcription must throttle itself
under thermal pressure, low memory, low power, and on lower-tier chips.
Idle models must free their weights.

Estimated size: 2 days.

## Track 3.1 — `ResourceGovernor`

### Design

Single `@Observable` service (`@MainActor` for its state, but the sensing
happens on background sources). Encapsulates all system-state sensing and
exposes an opaque `TranscriptionBudget` to consumers so we can evolve the
policy without touching call sites.

### Sensed signals

| Signal | Source | Update cadence |
|--------|--------|----------------|
| Thermal state | `ProcessInfo.processInfo.thermalState` + `NSProcessInfo.thermalStateDidChangeNotification` | Event-driven |
| Low power mode | `ProcessInfo.processInfo.isLowPowerModeEnabled` + `NSProcessInfoPowerStateDidChange` | Event-driven |
| Memory pressure | `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical])` on `.utility` queue | Event-driven |
| Chip family | `sysctlbyname("machdep.cpu.brand_string")` and `hw.perflevel0.physicalcpu` parsed once | One-shot at launch |
| Available RAM | `os_proc_available_memory()` | On-demand at budget request time |
| Power source | `IOPSCopyPowerSourcesInfo()` + `IOPSCopyPowerSourcesList()` | On-demand + polled every 30s while transcribing |

### Chip classification

Parse `machdep.cpu.brand_string`:
- Contains `M1` / `M2` / `M3` / `M4` — chip generation
- Presence of `Pro` / `Max` / `Ultra` — tier
- Everything else → `.air` class (or base M-chip)

Map:
- `.air` (base M-series, no Pro/Max/Ultra suffix)
- `.pro`
- `.max`
- `.ultra`
- `.unknown` (defensive)

### Budget calculation

```swift
public struct TranscriptionBudget: Sendable {
    public let maxConcurrency: Int
    public let allowANE: Bool
    public let allowParallel: Bool  // false => force sequential
    public let idleUnloadMinutes: Int
}
```

Policy (start conservative, tune with telemetry later):

| State | maxConcurrency | allowParallel |
|-------|---------------|---------------|
| Thermal `.critical` | 1 | false |
| Thermal `.serious` | 1 | true |
| Low power mode ON | 1 | true |
| On battery + thermal `.fair`+ | 1 | true |
| Air class, any state better than `.serious` | 1 | true |
| Pro class on AC, `.nominal` | 2 | true |
| Max/Ultra on AC, `.nominal` | 3 | true |

Then apply overrides:
- Memory pressure `.warning` observed within last 60s: floor concurrency
  to 1.
- Memory pressure `.critical` observed within last 60s: `allowParallel = false`.

### Files to create

- `gui/Sources/TranscribeerApp/Services/ResourceGovernor.swift` — the
  `@Observable` service. Exposes:
  - `currentBudget() -> TranscriptionBudget`
  - `thermalState`, `isLowPowerMode`, `chipClass`, `isOnBattery` as
    observable properties so the UI can render a "Reduced performance"
    banner.
- `gui/Sources/TranscribeerApp/Services/ChipClassifier.swift` — pure
  `sysctlbyname` parsing, easy to unit-test with fixture strings.
- `gui/Sources/TranscribeerCore/TranscriptionBudget.swift` — the
  `Sendable` value type so both layers can use it.
- `gui/Tests/TranscribeerTests/ResourceGovernorTests.swift` — pure
  policy tests (feed fake signals, assert budget).
- `gui/Tests/TranscribeerTests/ChipClassifierTests.swift` — table-driven
  parsing tests for known brand strings.

### Files to modify

- `gui/Sources/TranscribeerCore/ChunkedTranscriber.swift`:
  - Accept a `TranscriptionBudget` instead of `maxConcurrency: Int = 2`.
  - Honor `allowParallel = false` (sequential loop, no `TaskGroup`).
  - Add a checkpoint before spinning up each chunk that re-reads the
    budget so a mid-run thermal event downgrades subsequent chunks.
- `gui/Sources/TranscribeerApp/Services/TranscriptionService.swift`:
  - Inject the governor's budget when calling `ChunkedTranscriber`.
  - Read budget when calling `DualSourceTranscriber` too.
- `gui/Sources/TranscribeerApp/TranscribeerApp.swift` — instantiate
  `ResourceGovernor` at app root and pass down via environment.

### Acceptance criteria

- On a MacBook Air, `ChunkedTranscriber` never uses concurrency > 1.
- On a Pro-class chip on AC with nominal thermals,
  `ChunkedTranscriber` uses concurrency = 2.
- Simulated thermal `.serious` events (via
  `_setThermalState` on macOS test host, or wrapping the sensor for tests)
  downgrade an in-flight chunked run to sequential after the current
  batch completes.
- Memory pressure `.warning` cancels remaining chunks and continues at
  concurrency 1.
- Tests cover chip classification and policy calculation.

## Track 3.2 — Idle model unload

### Design

- Timer resets on every `TranscriptionService.transcribe(...)` invocation.
- After N minutes without transcription activity, `unloadModel()` is
  called; frees ~1.5-3 GB depending on model.
- Timer is paused while a transcription is in flight.
- Configurable via `AppConfig.idleUnloadMinutes` (default 10, 0 = never).

### Files to modify

- `gui/Sources/TranscribeerApp/Services/TranscriptionService.swift`:
  - Add `idleUnloadTimer: Task<Void, Never>?`.
  - `armIdleTimer()` called at the end of every transcription; cancels
    the previous timer and schedules a new one.
  - `disarmIdleTimer()` called at the start of every transcription.
  - Handles cancellation cleanly on `unloadModel()`.
- `gui/Sources/TranscribeerCore/Config.swift`:
  - New field `idleUnloadMinutes: Int` (default 10).
- `gui/Sources/TranscribeerApp/Views/TranscriptionSettingsView.swift` —
  add a numeric field "Unload model after N minutes idle (0 = never)".

### Acceptance criteria

- After a transcription completes, the model unloads within
  `idleUnloadMinutes + tolerance` minutes if no further transcription
  is started.
- Starting a new transcription within the window keeps the model loaded.
- Setting `idleUnloadMinutes = 0` disables the unload.
- No leak of timer tasks across repeated transcriptions (verified with
  a test that runs 100 transcribe/unload cycles).

## Track 3.3 — Pre-flight RAM check

### Design

- Before loading a large model (>= 1 GB), check
  `os_proc_available_memory()`. If available < required × 1.5, present an
  alert:
  - Title: "Not enough memory for this model"
  - Message: "Only 2.1 GB available; large-v3 needs ~4 GB. Free memory
    or switch to the turbo model (1.6 GB)."
  - Actions: "Use turbo instead" / "Try anyway" / "Cancel"
- Skipped when `idleUnloadMinutes` triggered a recent unload of a
  larger model on the same run (we already know how much RAM we had).

### Files to modify

- `gui/Sources/TranscribeerApp/Services/TranscriptionService.swift` —
  `loadModel(name:repo:)` performs the pre-flight check before invoking
  the `WhisperKit` initializer.
- `gui/Sources/TranscribeerApp/Services/ModelCatalogService.swift` —
  expose expected RAM per model (hardcoded table indexed by canonical
  model name).

### Acceptance criteria

- Loading `openai_whisper-large-v3` on a machine with <6 GB available
  memory shows the alert.
- Loading `openai_whisper-large-v3-turbo` in the same conditions does
  not show the alert.

## Track 3.4 — Reduced-performance banner (UX surface for the above)

### Design

- Small banner rendered in the menu bar popover / main window when
  `ResourceGovernor` reports a degraded state:
  - Thermal `.serious`+ → "Reduced performance — Mac is warm."
  - Low power → "Reduced performance — Low Power Mode is on."
  - Memory pressure recent → "Reduced performance — memory low."
- Non-dismissable; clears itself when the state recovers.
- Chevron opens a diagnostic sheet with the raw governor state (for
  debugging).

### Files to create

- `gui/Sources/TranscribeerApp/Views/ResourceStatusBanner.swift`

### Files to modify

- Wherever the main popover / settings root lives — add the banner above
  the primary content when a degraded state is active.

### Acceptance criteria

- Manually toggling Low Power Mode in System Settings surfaces the
  banner within ~2 seconds.
- Banner disappears when Low Power Mode is turned off.
