# Phase 4 — Export, Hotkey, Prompt, Integrations

Estimated size: 2-3 days.

## Track 4.1 — SRT/VTT export

### Design

We already produce `[LabeledSegment]` with `start`, `end`, `speaker`,
`text`. SRT and VTT are trivial formatters over that array.

### Files to modify

- `gui/Sources/TranscribeerCore/TranscriptFormatter.swift`:
  - `public static func formatSRT([LabeledSegment]) -> String`
  - `public static func formatVTT([LabeledSegment]) -> String`
  - Both include speaker as an inline prefix (`<v Speaker 1>Text</v>` for
    VTT; `[Speaker 1] Text` for SRT).
- `gui/Sources/TranscribeerApp/Views/SessionDetailView.swift` — Export
  menu with SRT / VTT / TXT items. Uses `NSSavePanel`.
- `gui/Sources/TranscribeerApp/Services/PipelineRunner.swift` — after
  successful transcription, if the `pipeline.autoExportFormats` config
  contains `srt` / `vtt`, write the extra file alongside `transcript.txt`.
- `gui/Sources/TranscribeerCore/Config.swift` — new field
  `autoExportFormats: [String]` (default `[]`).
- `gui/Sources/TranscribeerApp/Views/IntegrationsSettingsView.swift`
  (see Track 4.4) — toggles for auto-export.
- `gui/Tests/TranscribeerTests/TranscriptFormatterTests.swift` — add SRT
  and VTT test cases (timing conversion, speaker prefixing, RTL handling
  for Hebrew).

### Acceptance criteria

- `formatSRT` produces valid SRT (numbered blocks, `HH:MM:SS,mmm -->
  HH:MM:SS,mmm` timings).
- `formatVTT` produces valid WebVTT (`WEBVTT` header, `HH:MM:SS.mmm`
  timings, `<v Speaker>` cues).
- Round-trip: pasting the SRT into VLC and playing the audio shows the
  captions in sync.
- Manual export via UI writes the file to the chosen location.
- Auto-export writes `transcript.srt` / `transcript.vtt` into the
  session directory when the config toggle is on.

## Track 4.2 — Global hotkey

### Design

- Default binding: **⌘⇧T** ("Transcribeer"). User-configurable.
- Uses Carbon `RegisterEventHotKey` — the same API `AppKit` recommends
  for global hotkeys. `NSEvent.addGlobalMonitorForEvents` doesn't work
  when the app isn't active, which is exactly when we need to activate.
- Requires **Accessibility** permission (already prompted in the
  onboarding Permissions page).
- Action: brings the app forward and shows the menu bar popover.
- Groundwork for future dictation-at-cursor (Phase 5) which will
  register additional hotkeys through the same manager.

### Files to create

- `gui/Sources/TranscribeerApp/Services/GlobalHotkeyManager.swift`:
  - `register(id:keyCode:modifiers:handler:)`
  - `unregister(id:)`
  - `unregisterAll()`
  - Internally maps Carbon hotkey IDs to closures via a mutable dict.
  - Uses `InstallEventHandler` on `EventTargetRef` in
    `GetApplicationEventTarget()`.
- `gui/Sources/TranscribeerApp/Views/HotkeySettingsView.swift` —
  hotkey recorder input (click to record, shows current binding, "Reset
  to default" button).
- `gui/Tests/TranscribeerTests/GlobalHotkeyManagerTests.swift` — pure
  logic tests for keycode encoding and modifier mapping.

### Files to modify

- `gui/Sources/TranscribeerApp/AppDelegate.swift` — register the "open
  app" hotkey on `applicationDidFinishLaunching`, unregister on
  termination.
- `gui/Sources/TranscribeerCore/Config.swift` — new field
  `openAppHotkey: String?` (encoded as e.g. `cmd+shift+t`). Nil means
  disabled. Default: `cmd+shift+t`.
- `gui/Sources/TranscribeerApp/Views/SettingsView.swift` — add
  "Hotkeys" section pointing to `HotkeySettingsView`.
- `gui/Transcribeer.entitlements.plist` — verify Accessibility is not
  entitlement-gated (it's a TCC prompt, not sandbox); document in
  `docs/PERMISSIONS.md` if missing.

### Acceptance criteria

- Pressing ⌘⇧T from any focused app brings Transcribeer forward.
- Rebinding to a different combo works and persists across restarts.
- Clearing the hotkey disables it (no accidental activations).
- Hotkey does not fire when the app doesn't have Accessibility
  permission; a warning is shown in Settings when the binding is
  configured but permission is missing.

## Track 4.3 — Post-recording prompt

### Design

- New config field `pipeline.promptOnStop: Bool` (default false).
- When true, `PipelineRunner.stopRecording()` shows a sheet before
  running the rest of the pipeline. Options:
  - Rename session (inline text field)
  - Transcribe now (current behavior — proceeds through pipeline)
  - Just save (skips transcribe + summarize; state → `.done`)
  - Summarize with profile… (opens profile picker, uses selected)
  - Cancel (throws away the recording after confirmation)
- When false, current auto-pipeline runs unchanged. No behavior change
  for existing users unless they flip the toggle.

### Files to create

- `gui/Sources/TranscribeerApp/Views/PostRecordingSheet.swift`

### Files to modify

- `gui/Sources/TranscribeerCore/Config.swift` — add
  `pipeline.promptOnStop: Bool` (default false).
- `gui/Sources/TranscribeerApp/Services/PipelineRunner.swift`:
  - `runPipeline` splits its recording-completed branch: if
    `promptOnStop`, publish an event that the UI observes to show the
    sheet, and await the user's action before proceeding.
  - Add a `pendingAction: PostRecordingAction?` observable so the sheet
    can push its choice back into the runner.
- `gui/Sources/TranscribeerApp/Views/SettingsView.swift` — add
  "Pipeline" section with the toggle + description.

### Acceptance criteria

- Default install behaves like today (no sheet).
- Toggling `promptOnStop` on shows the sheet after every stop.
- Rename applies before transcript files are written (transcript header
  matches the new name in Obsidian, etc.).
- "Just save" leaves audio files but no transcript / summary; session
  can still be transcribed later from history.
- Cancel with confirmation removes the session folder entirely.

## Track 4.4 — Integrations settings

### Design

Single Settings section that owns the "what to do with the transcript"
side-effects. Each integration is one config field driving one hook in
`PipelineRunner.finishSession`.

### Integrations for v1

- **Obsidian** — vault path picker + auto-import toggle.
  - Currently the plugin polls a folder; we can still support that.
  - Config: `integrations.obsidian.enabled: Bool`,
    `integrations.obsidian.vaultPath: String`.
- **Clipboard** — auto-copy summary on completion.
  - Config: `integrations.clipboard.copySummary: Bool`,
    `integrations.clipboard.copyTranscript: Bool`.
- **File export** — auto-save additional transcript formats.
  - Config: `integrations.export.formats: [String]` (`srt`, `vtt`, both).
  - Overlaps with Track 4.1; unify under one config key.

### Files to create

- `gui/Sources/TranscribeerApp/Views/IntegrationsSettingsView.swift`
- `gui/Sources/TranscribeerApp/Services/IntegrationDispatcher.swift` —
  called by `PipelineRunner.finishSession`; iterates configured
  integrations and invokes each.

### Files to modify

- `gui/Sources/TranscribeerCore/Config.swift` — new
  `IntegrationsConfig` nested struct.
- `gui/Sources/TranscribeerApp/Services/PipelineRunner.swift` —
  invoke `IntegrationDispatcher.dispatch(session:config:)` from
  `finishSession`.
- `gui/Sources/TranscribeerApp/Views/SettingsView.swift` — add
  Integrations tab.

### Acceptance criteria

- Toggling clipboard integration copies the summary to the pasteboard
  when a recording finishes.
- Toggling Obsidian integration writes the note to the configured vault
  path (or the plugin still handles that — verify no double-writes).
- Toggling SRT auto-export writes `transcript.srt` to the session.
- All integrations are best-effort; a failure in one does not block
  the pipeline (errors logged to `run.log`).

## Track 4.5 — Long-recording confirmation

### Design

- Before summarization, if audio duration > `pipeline.longRecordingThresholdMinutes`
  (default 30), show a confirmation with the estimated token count and
  time (from `ETAEstimator`).
- Actions: Summarize / Just save transcript / Cancel.
- Threshold configurable; set to 0 to disable.

### Files to modify

- `gui/Sources/TranscribeerCore/Config.swift` — add
  `pipeline.longRecordingThresholdMinutes: Int` (default 30).
- `gui/Sources/TranscribeerApp/Services/PipelineRunner.swift` —
  gate `performSummarization` on the threshold check + a callback the
  UI can respond to.
- `gui/Sources/TranscribeerApp/Views/SessionDetailView.swift` — the
  confirmation sheet.

### Acceptance criteria

- Recording < 30 min: no prompt.
- Recording > 30 min with threshold = 30: prompt appears.
- Choosing "Just save transcript" completes the pipeline without
  invoking the LLM.
- Choosing "Summarize" proceeds normally.
- Threshold = 0 disables the check.
