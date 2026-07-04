# Phase 5 — Follow-ups (deferred)

These are documented so we don't lose them. Not in the current initiative;
each is a separate PR after Phase 4 lands.

## 5.1 — Map-reduce summarization for long recordings

**Problem**: a 90-minute transcript is 15-25k tokens; feeding it to the
LLM at once is slow, expensive, and often exceeds context windows.

**Approach**:

1. Split transcript into ~15-min windows (respect speaker boundaries;
   avoid cutting mid-sentence).
2. Summarize each window in parallel via concurrent LLM calls (bounded
   by the LLM backend's rate limit).
3. Reduce: feed the per-window summaries into a final "combine" LLM
   call that produces the final markdown summary.
4. Stream partial reductions as they land so the UI shows progress.

**New service**: `MapReduceSummarizer` in `Sources/TranscribeerCore/`.

**Concurrency**: use the same `ResourceGovernor` budget to cap parallel
LLM calls (network calls are cheap CPU-wise, but memory-cheap doesn't
mean cost-cheap; also cloud rate limits matter).

**Config**: `summarization.mapReduce.enabled: Bool`,
`summarization.mapReduce.windowMinutes: Int` (default 15).

## 5.2 — Silence removal

**Problem**: multi-hour recordings may have significant silence
(muted mic during meetings). Removing it reduces disk usage and
transcription cost.

**Precondition**: measure first. Instrument a "silence percentage"
counter on completed recordings for a week. If <15% average, skip.
If >30%, ship an opt-in. VAD already runs in WhisperKit; we can reuse
its silence markers.

**Approach if we ship**:
- Post-recording, run a lightweight VAD pass over the raw CAF files.
- Emit a `silence_ranges.json` alongside the recording.
- During transcription, skip chunks that are entirely silent.
- Optionally offer to trim silent regions from the final audio (opt-in;
  destructive).

**Config**: `audio.trimSilence: Bool` (default false).

## 5.3 — Dictation-at-cursor

**Problem**: system dictation on macOS is mediocre for Hebrew.
On-device Whisper transcription behind a global hotkey would fix that.

**Approach**:
- Register additional hotkeys via `GlobalHotkeyManager` (built in
  Phase 4.2): e.g. `⌘⇧E` for English, `⌘⇧H` for Hebrew.
- On hold: record from the mic; on release: run WhisperKit on the
  buffer; paste the result at the current cursor via `CGEventPost`.
- Requires Accessibility (already granted in the onboarding).

**New services**:
- `DictationController` — coordinates capture + transcribe + paste.
- `PasteAtCursorService` — CGEventPost wrapper.

**Config**: `dictation.english.hotkey`, `dictation.hebrew.hotkey`.

## 5.4 — Launch-at-login toggle

**Problem**: Cask-installed apps don't ship with a LaunchAgent. Users
who want the app running on login must add it via System Settings.

**Approach**: use `SMAppService.mainApp.register()` (macOS 13+) exposed
via a Settings toggle. Removes the need for the dev-time LaunchAgent
in production.

## 5.5 — Localization

**Problem**: UI is English-only. Hebrew users transcribing Hebrew audio
would benefit from a Hebrew UI.

**Approach**: extract user-facing strings into `Localizable.strings`,
add Hebrew translations. Ensure RTL layout works for the whole app,
not just transcript rendering.
