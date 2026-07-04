# Phase 2 — Onboarding & Language Routing

Goals: first-run wizard that gets a non-technical user from install to first
successful recording in <5 minutes, including Hebrew model download and
permission grants. Existing users get the same wizard on first launch after
update so they benefit from language routing and the permissions audit.

Estimated size: 2-3 days.

## Track 2.1 — Onboarding wizard

### Design

- 5 pages in a `TabView` with a hidden tab bar, driven by an
  `OnboardingStep` enum. Custom `Back` / `Continue` buttons at the bottom.
- Wizard opens as a **sheet** over the main window. Skippable at any point
  via a small `Skip setup` link — sets `hasCompletedOnboarding = true` and
  closes. Skippers can re-run from Settings.
- Trigger conditions:
  - `UserDefaults.hasCompletedOnboarding == false` on app launch.
  - Users on older versions get `hasCompletedOnboarding` treated as
    `false` — retroactive one-time wizard. Set a `lastOnboardingVersion`
    key so future onboarding updates can re-trigger only when there's
    something new.
- All wizard settings are reachable from Settings later; the wizard is a
  guided path, not a special mode.

### Pages

1. **Welcome** — one-line pitch, hero image (optional, reuse
   `assets/logo.png`), "Get started" primary button.
2. **Language** — checkboxes for English and Hebrew (both pre-checked).
   "You can add more languages later in Settings." Continue disabled until
   ≥1 language is selected.
3. **Models** — one row per selected language showing:
   - Model name + display size (e.g. "openai_whisper-large-v3-turbo · 1.6 GB").
   - Progress bar during download.
   - ✓ badge when already present on disk (skip download).
   - Continue button becomes "Continue in background" once any download
     starts; wizard proceeds and downloads finish under a Settings banner.
4. **Permissions** — one card per permission:
   - Microphone (`Privacy & Security → Microphone`)
   - System Audio Recording (`Privacy & Security → Screen Recording` — the
     entitlement name is a legacy misnomer)
   - Accessibility (needed for the global hotkey in Phase 4; still shown
     here so users grant it once)
   - Each card has a Grant button that opens the exact pane via
     `x-apple.systempreferences:com.apple.preference.security?<anchor>`.
   - Live status: the wizard re-checks TCC / AX permission every 500 ms
     while the page is visible and flips the ✓ when granted.
   - Continue button always enabled (permissions are optional; the user
     will be re-prompted when a feature needs them anyway).
5. **Ready** — success illustration, list of next steps ("Click the
   menubar icon to start your first recording", "Explore Settings to
   customize the pipeline"), Done button.

### Files to create

- `gui/Sources/TranscribeerApp/Views/Onboarding/OnboardingSheet.swift` —
  root sheet + page routing + step enum + Back/Continue bar.
- `gui/Sources/TranscribeerApp/Views/Onboarding/OnboardingWelcomeView.swift`
- `gui/Sources/TranscribeerApp/Views/Onboarding/OnboardingLanguageView.swift`
- `gui/Sources/TranscribeerApp/Views/Onboarding/OnboardingModelsView.swift`
- `gui/Sources/TranscribeerApp/Views/Onboarding/OnboardingPermissionsView.swift`
- `gui/Sources/TranscribeerApp/Views/Onboarding/OnboardingReadyView.swift`
- `gui/Sources/TranscribeerApp/Services/OnboardingState.swift` —
  `@Observable`, persists to `UserDefaults`:
  - `hasCompletedOnboarding: Bool`
  - `lastOnboardingVersion: String`
  - `selectedLanguages: Set<Language>` (transient during wizard)
- `gui/Sources/TranscribeerApp/Services/PermissionsProbe.swift` — polls
  TCC via `AVCaptureDevice.authorizationStatus(for: .audio)`,
  `CGPreflightScreenCaptureAccess()`,
  `AXIsProcessTrustedWithOptions(...)`. Exposes `@Observable` state so the
  onboarding page and the future Settings health card share code.
- `gui/Tests/TranscribeerTests/OnboardingStateTests.swift`

### Files to modify

- `gui/Sources/TranscribeerApp/TranscribeerApp.swift` — present the
  onboarding sheet on first launch. Hook into `AppDelegate` or the
  root view's `.task`.
- `gui/Sources/TranscribeerApp/Views/SettingsView.swift` — add
  "Re-run setup" button that resets `hasCompletedOnboarding` and reopens
  the sheet.

### Acceptance criteria

- Fresh install (empty `UserDefaults`) shows the wizard on launch.
- Existing install (older `lastOnboardingVersion`) shows the wizard once
  after update.
- Language step blocks Continue when nothing is selected.
- Model step downloads run in background; wizard can proceed with
  partial completion (banner shows on Settings when downloads finish).
- Permissions step reflects real TCC state within ~1 second of granting.
- Wizard is re-runnable from Settings without re-downloading models that
  already exist on disk.
- Skip button closes the wizard and never shows again automatically.

## Track 2.2 — Language routing + curated model catalog

### Design

- Ship a hardcoded curated list of "recommended" models mixed with any
  locally downloaded ones:
  - Hebrew — recommended (turbo): our repackaged
    `ivrit-ai_whisper-large-v3-turbo` (from Phase 1.2)
  - Hebrew — most accurate: our repackaged `ivrit-ai_whisper-large-v3`
  - English — recommended: `argmaxinc/whisperkit-coreml /
    openai_whisper-large-v3-turbo`
  - Multilingual (fallback for unlisted languages):
    `argmaxinc/whisperkit-coreml / openai_whisper-large-v3`
- Auto-routing: `TranscriptionService.transcribe(session:config:)` picks
  the model at call time based on `config.language` (or, when `auto`, the
  language WhisperKit detected on the previous run for that session or,
  first-time, the multilingual model with `detectLanguage: true`).

### Files to modify

- `gui/Sources/TranscribeerApp/Services/ModelCatalogService.swift` —
  interleave the curated list ahead of the remote catalog. Mark the
  Hebrew entries with a special `.curated` flag so the picker groups them
  under a "Recommended" section.
- `gui/Sources/TranscribeerCore/Config.swift`:
  - New fields:
    - `hebrewWhisperModel: String` (default: `ivrit-ai_whisper-large-v3-turbo`)
    - `hebrewWhisperModelRepo: String?` (default: `nil`, uses local cache
      populated by `HebrewModelDownloader`)
    - `englishWhisperModel: String` (default:
      `openai_whisper-large-v3-turbo`)
    - `englishWhisperModelRepo: String?` (default: `nil`, uses
      `argmaxinc/whisperkit-coreml`)
  - Migration: existing configs keep working; new fields default when
    missing.
- `gui/Sources/TranscribeerApp/Services/TranscriptionService.swift`:
  - `transcribe(session:config:)` computes an "effective model" from
    `config.language` before delegating to `transcribeLocal` /
    `transcribeCloud`.
  - When language is `auto`, run first-pass detection with the
    multilingual model, then swap to the language-specific model if the
    detected language is `he` or `en` and a curated model is available.
    (Second-pass swap is an optimization — for v1 we can just run the
    multilingual model end-to-end when `auto` is chosen and only swap
    for known-language runs. Documented as a follow-up.)
- `gui/Sources/TranscribeerApp/Views/TranscriptionSettingsView.swift` —
  replace the single "Model" picker with:
  - "Hebrew model" picker (curated list only)
  - "English model" picker (curated list only)
  - "Other languages" picker (full remote catalog)
  - Keep the custom-repo escape hatch for power users.

### Acceptance criteria

- Recording a Hebrew audio file with `config.language = "he"` uses the
  ivrit.ai CoreML model.
- Recording an English audio file with `config.language = "en"` uses
  `openai_whisper-large-v3-turbo`.
- `config.language = "auto"` still works (uses multilingual model with
  detection enabled).
- Existing configs load without errors after the migration.

## Track 2.3 — Language auto-detect UX

### Design

- After transcription, persist the detected language into session
  metadata alongside `transcript.txt`.
- `SessionDetailView` shows a chip near the transcript header: e.g.
  `Detected: Hebrew` with a small dropdown to override + re-transcribe.
- `RetranscribeMenu` already supports language overrides — verify it
  surfaces this cleanly.

### Files to modify

- `gui/Sources/TranscribeerApp/Services/SessionManager.swift` (or wherever
  session metadata lives — check `Models/Session*`) — add
  `detectedLanguage: String?` field to the persisted session metadata.
- `gui/Sources/TranscribeerApp/Services/TranscriptionService.swift` —
  when `config.language == "auto"`, capture the language WhisperKit
  reports for the first non-silent segment and persist it via
  SessionManager after successful transcription.
- `gui/Sources/TranscribeerApp/Views/SessionDetailView.swift` — render
  detected-language chip + override menu.
- `gui/Sources/TranscribeerApp/Models/TranscriptionLanguage.swift` —
  ensure display names and codes cover the languages we surface.

### Acceptance criteria

- Recording a Hebrew audio with `language = "auto"` results in a session
  whose `detectedLanguage == "he"`.
- The chip displays "Hebrew" and the override menu offers "Re-transcribe
  as English / Hebrew / other…".
- Existing sessions without `detectedLanguage` show no chip (nil-safe).

## Notes / dependencies

- Track 2.1 depends on Track 1.2 (HebrewModelDownloader must exist for
  the Models page to actually download the Hebrew model). If Phase 1
  isn't merged when 2.1 is under way, the Models page can stub out the
  Hebrew download and be wired up later.
- Track 2.2 depends on Track 1.2 for the Hebrew model catalog entries.
