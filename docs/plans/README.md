# Product Improvements — Master Plan

Cross-cutting initiative to improve installation, resource utilization, and UX.
Each phase has its own document under `docs/plans/`. Each track is scoped so it
can be handed to an agent with minimal context transfer.

## Goals

1. **Installation**: fix broken Homebrew tap, add DMG distribution, remove
   friction for non-technical users (esp. Hebrew speakers who need ivrit.ai).
2. **macOS optimization**: adaptive concurrency, thermal / memory / power
   awareness, model idle-unload — so a long transcription never freezes the
   laptop.
3. **UX**: first-run onboarding wizard, language auto-detection surfaces,
   global hotkey, post-recording prompt, integration targets, SRT/VTT export.

## Non-goals for this initiative

- Real-time / live transcription mode
- Dictation-at-cursor (paste transcription into focused field)
- Silence removal (needs benchmarking on real recordings first — deferred)
- Developer ID code signing / notarization
- Sparkle auto-updates (Homebrew + DMG covers distribution)

## Phase overview

| Phase | Theme | Docs |
|-------|-------|------|
| 1 | Distribution: Cask rewrite + DMG + Hebrew models on GH Releases | [phase-1-distribution.md](phase-1-distribution.md) |
| 2 | First-run onboarding + language routing + auto-detect UX | [phase-2-onboarding.md](phase-2-onboarding.md) |
| 3 | `ResourceGovernor` + adaptive concurrency + idle unload | [phase-3-resource-optimization.md](phase-3-resource-optimization.md) |
| 4 | SRT/VTT + global hotkey + post-recording prompt + integrations | [phase-4-ux-polish.md](phase-4-ux-polish.md) |
| 5 (deferred) | Map-reduce summarization + silence removal + dictation | [phase-5-followups.md](phase-5-followups.md) |

## Locked-in decisions

- **Homebrew**: rewrite as a **Cask** under `Casks/` subdir in the existing
  `moshebe/homebrew-pkg` tap. Old `transcribeer.rb` (Python-era formula) is
  removed in the same tap PR.
- **Distribution**: DMG artifact produced by `make dmg`, attached to GitHub
  releases by CI, referenced by the Cask.
- **Hebrew models**: convert `ivrit-ai/whisper-large-v3-turbo` and
  `ivrit-ai/whisper-large-v3` to CoreML using the vendored `whisperkittools/`,
  publish as GitHub Release assets (tag `models-v1`, `models-v2`, …), separate
  from app-version tags. No HuggingFace org needed.
- **CoreML rationale**: identical accuracy to GGML (same fine-tuned weights),
  lower power draw via ANE, seamless integration with existing WhisperKit +
  SpeakerKit stack, no second inference engine to maintain, diarization keeps
  working on Hebrew.
- **Trust**: pin SHA-256 of each model tarball in the app so a compromised
  GitHub tag cannot inject arbitrary CoreML binaries.
- **Onboarding**: 5-page wizard (Welcome → Language → Models → Permissions →
  Ready). Language: English + Hebrew both pre-checked, must select ≥1. Model
  download is non-blocking (continues in Settings banner if user proceeds).
  Retroactively shown to existing users on first launch after update.
- **Global hotkey**: default `⌘⇧T`, configurable in Settings → Hotkeys.
  Activates the app / shows the menu bar popover.
- **Post-recording prompt**: config toggle `pipeline.promptOnStop`, default
  **off** (auto-pipeline preserves current behavior for existing users).
- **Integration targets v1**: Obsidian (already has plugin), Clipboard,
  File Export (SRT/VTT/TXT).
- **Idle model unload**: 10 min default, configurable.
- **Long-recording threshold**: 30 min prompt-before-summarize, configurable.

## Execution model

- Each phase is one PR.
- Each track inside a phase is one commit or one sub-PR depending on scope.
- Agents pick up individual tracks; each track's doc lists files to create,
  files to modify, and acceptance criteria.
- `swift build && make lint` must pass before any track is called done.
