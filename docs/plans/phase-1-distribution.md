# Phase 1 — Distribution

Goals: fix Homebrew, add DMG distribution, publish Hebrew CoreML models as
GitHub Release assets so the onboarding wizard (Phase 2) has something to
download.

Estimated size: 1-2 days.

## Track 1.1 — Homebrew Cask + DMG build

### Context

The current `moshebe/homebrew-pkg/transcribeer.rb` at the tap root is the
pre-Swift Python formula. Every reference in it is dead
(`pip install .[gui,resemblyzer,openai,anthropic]`, `capture-bin` in tarball,
`transcribeer-gui` Python entry point). The project is now pure Swift +
WhisperKit — the formula must be replaced, not patched.

### Design

- Replace the Formula with a **Cask** under `moshebe/homebrew-pkg/Casks/`.
  Casks are Homebrew's blessed primitive for GUI `.app` bundles. Coexists
  with existing tap Formulas (`gcpql`, `gebug`, `gtrace`) at repo root.
- User install becomes: `brew install --cask moshebe/pkg/transcribeer`.
- Cask downloads a DMG asset from a GitHub Release and drag-installs the
  `.app` into `/Applications`.
- Ad-hoc code signed (matches current `Makefile` behavior; no Developer ID).
- Include `zap` stanza to clean `~/.transcribeer/` on `brew uninstall --zap`.

### Files to create

- `scripts/make-dmg.sh` — builds `Transcribeer-<version>.dmg`:
  - Reuses `make build-release` output at `gui/.build/Transcribeer.app`.
  - Creates a staging folder with the `.app` + an `Applications` symlink for
    drag-drop UX.
  - Uses `hdiutil create -format UDZO` (widely compatible, decent
    compression). Falls back to `create-dmg` if installed for prettier
    background image (optional).
  - Writes DMG to `dist/Transcribeer-<version>.dmg`.
  - Computes SHA-256, prints URL fragment that goes into the Cask.
- `.github/workflows/release.yml` — triggered on `v*` tag:
  - Runs on macOS-latest.
  - `make build-release` + `make dmg`.
  - Attaches DMG to the release via `gh release upload`.
  - Opens a PR against `moshebe/homebrew-pkg` bumping the Cask's
    `version` and `sha256`. Uses a fine-grained PAT stored as
    `HOMEBREW_TAP_TOKEN` secret.
- `Casks/transcribeer.rb` (in the tap repo, delivered as a PR from CI or
  manually first time):

  ```ruby
  cask "transcribeer" do
    version "0.2.0"
    sha256 "..."
    url "https://github.com/moshebe/transcribeer/releases/download/v#{version}/Transcribeer-#{version}.dmg"
    name "Transcribeer"
    desc "Local-first meeting transcription and summarization for macOS"
    homepage "https://github.com/moshebe/transcribeer"

    depends_on macos: ">= :sequoia"
    depends_on arch: :arm64

    app "Transcribeer.app"

    zap trash: [
      "~/.transcribeer",
      "~/Library/Preferences/com.transcribeer.menubar.plist",
      "~/Library/LaunchAgents/com.transcribeer.dev.plist",
    ]
  end
  ```

### Files to modify

- `Makefile` — add `dmg` and `release VERSION=x.y.z` targets. The `release`
  target tags, pushes, and lets CI take over. Remove or replace the existing
  `release` target which currently expects Python source archives.
- `README.md` — install section:
  - Primary: `brew install --cask moshebe/pkg/transcribeer`.
  - Alternative: download DMG from Releases (right-click → Open for
    Gatekeeper on first launch).
  - Remove the `brew tap moshebe/pkg && brew install transcribeer` line.
  - Remove `brew services start transcribeer` — Cask apps use LaunchAgent
    the app installs itself, or the user drags to Login Items. The current
    dev-time LaunchAgent (`com.transcribeer.dev.plist`) is dev-only and
    should not ship with the Cask. Document how to set "Open at Login"
    via System Settings, or add an in-app "Launch at login" toggle in a
    follow-up.

### Acceptance criteria

- `make dmg` on a clean checkout produces `dist/Transcribeer-<version>.dmg`
  that:
  - Mounts cleanly.
  - Contains `Transcribeer.app` and an `Applications` symlink.
  - Launches and passes Gatekeeper on right-click → Open.
- CI workflow runs on tag push, attaches DMG to release.
- CI opens a Cask update PR against `moshebe/homebrew-pkg`.
- Manual `brew install --cask moshebe/pkg/transcribeer` on a fresh Mac
  installs and launches the app.
- `brew uninstall --zap transcribeer` removes `~/.transcribeer/` and prefs.

### Out of scope

- Notarization (requires paid Developer ID).
- Auto-updates (Cask handles updates via `brew upgrade`).
- Login-item toggle (follow-up).

## Track 1.2 — Hebrew CoreML models via GitHub Releases

### Context

ivrit.ai publishes PyTorch, CTranslate2, GGML, and ONNX variants of their
Hebrew Whisper fine-tunes, but no CoreML. Our stack is WhisperKit (CoreML),
so we must convert & host ourselves. Skipping HuggingFace hosting — we
publish tarballs as GitHub Release assets on a dedicated `models-v*` tag,
separate from app-version tags, so model updates don't require app releases
and vice versa.

Legal: ivrit.ai models are Apache-2.0. Redistribution with attribution is
compliant. See ivrit.ai's Interspeech 2025 citation in their HF org card.

### Design

- **Conversion**: use vendored `whisperkittools/whisperkit-generate-model`
  to convert each ivrit.ai HF repo to WhisperKit's CoreML layout
  (`AudioEncoder.mlmodelc`, `TextDecoder.mlmodelc`, `MelSpectrogram.mlmodelc`,
  tokenizer files, config JSON).
- **Packaging**: tar+zstd each variant folder (better compression than gzip
  for `.mlmodelc` binaries). Filename convention:
  `ivrit-ai_whisper-large-v3-turbo.tar.zst`.
- **Publishing**: `gh release create models-v1 --title "Models v1" ...`
  attaches both variants.
- **Trust**: SHA-256 of each tarball is pinned in Swift source
  (`Sources/TranscribeerCore/ModelManifest.swift`). A future tag with a
  different SHA will fail verification and refuse to install — protects
  against a compromised GitHub token / release.
- **Client resolution**: the app doesn't hit the GitHub API at runtime. The
  URL, SHA-256, and expected extracted folder name for each model are
  compiled into the binary; updates ship with app updates.
- **Cache layout**: extract into
  `~/.transcribeer/models/models/argmaxinc/whisperkit-coreml/<variant>/` —
  matches what WhisperKit's `HubApi` produces so
  `TranscriptionService.cachedModelFolder` (already implemented at
  `gui/Sources/TranscribeerApp/Services/TranscriptionService.swift:152-182`)
  picks it up transparently. WhisperKit is passed `modelFolder:` explicitly
  and skips its own HF resolution.

### Files to create

- `scripts/publish-ivrit-coreml.sh` — reproducible conversion + upload:
  1. Assumes `whisperkittools` venv is set up (documented in the script).
  2. Runs `whisperkit-generate-model --model-version ivrit-ai/whisper-large-v3-turbo`
     and `--model-version ivrit-ai/whisper-large-v3`.
  3. Tars each output folder with `tar --zstd -cf <name>.tar.zst <folder>`.
  4. Computes SHA-256 and prints alongside the URL.
  5. `gh release create models-v1 --title "Models v1" --notes-file NOTES.md
     ivrit-ai_whisper-large-v3-turbo.tar.zst
     ivrit-ai_whisper-large-v3.tar.zst`.
- `gui/Sources/TranscribeerCore/ModelManifest.swift` — pinned metadata:
  ```swift
  public struct ModelManifestEntry: Sendable {
      public let id: String            // e.g. "ivrit-ai_whisper-large-v3-turbo"
      public let displayName: String   // "Hebrew — turbo (ivrit.ai)"
      public let sizeBytes: Int64
      public let sha256: String
      public let downloadURL: URL
      public let extractedFolderName: String
  }

  public enum ModelManifest {
      public static let all: [ModelManifestEntry] = [ /* … */ ]
      public static let hebrewTurbo: ModelManifestEntry = …
      public static let hebrewLarge: ModelManifestEntry = …
  }
  ```
- `gui/Sources/TranscribeerApp/Services/HebrewModelDownloader.swift` —
  runtime downloader:
  - `URLSession` download task with progress callback (throttled ≥1%).
  - Verifies SHA-256 after download.
  - Extracts via `Process` invoking `/usr/bin/tar --zstd -xf`.
  - Places into the WhisperKit cache layout under `~/.transcribeer/models/`.
  - Cleans up tarball after successful extraction.
  - Idempotent: skips download if the target folder already contains the
    required `.mlmodelc` bundles.
  - Exposes `@Observable` progress state for the onboarding UI (Phase 2)
    and a Settings banner.
- `gui/Tests/TranscribeerTests/HebrewModelDownloaderTests.swift` — SHA
  verification, cache-layout smoke, resume behavior.
- `docs/HEBREW_MODEL.md` — human-readable pipeline docs:
  - Why CoreML (ANE power efficiency, integration with SpeakerKit).
  - How to re-convert when ivrit.ai releases updates.
  - How to bump `ModelManifest.swift` and cut a `models-v*` release.

### Files to modify

- `NOTICE` — add ivrit.ai attribution + Interspeech 2025 citation.
- `README.md` — mention Hebrew as first-class supported language, credit
  ivrit.ai.
- `.gitignore` — exclude `whisperkittools/` build artifacts and any local
  model conversion outputs.

### Acceptance criteria

- `scripts/publish-ivrit-coreml.sh` runs end-to-end on a machine with
  `whisperkittools` installed and produces two verified tarballs uploaded
  to a `models-v1` GitHub Release.
- `HebrewModelDownloader.download(.hebrewTurbo)` on a fresh
  `~/.transcribeer/models/` produces a folder WhisperKit can load without
  hitting the network. Verified by loading a WhisperKit instance with
  `modelFolder:` set to the extracted path and running a short Hebrew
  sample.
- SHA mismatch causes the downloader to throw and clean up partial state.
- Cancelling mid-download leaves no orphaned files.
- Tests pass under `swift test`.

### Out of scope

- Runtime discovery of new `models-v*` releases (updates ship with app
  updates).
- Delta downloads (models are ~1.6 GB, we always fetch the whole tarball).
- Model quantization or optimization beyond `whisperkittools` defaults.
