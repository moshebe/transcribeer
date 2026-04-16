<div align="center">
  <img src="assets/logo-readme.png" width="120" alt="Transcribeer logo"/>
  <h1>Transcribeer 🍺</h1>
  <p><strong>Local-first meeting transcription and summarization for macOS</strong></p>
  <p>
    <img src="https://img.shields.io/badge/macOS-15%2B-blue?logo=apple" alt="macOS 15+"/>
    <img src="https://img.shields.io/badge/Apple_Silicon-arm64-green" alt="Apple Silicon"/>
    <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"/>
  </p>
</div>

---

Transcribeer captures both sides of any call, transcribes with speaker labels, and optionally summarizes with an LLM — all running locally on your Mac. No cloud required. Zero Python dependencies.

## Features

- **System audio capture** — records both microphone and speaker audio via Apple ScreenCaptureKit
- **On-device transcription** — [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML, Apple Silicon optimized), Hebrew and multilingual
- **Speaker diarization** — who said what, via [SpeakerKit](https://github.com/argmaxinc/WhisperKit) (Pyannote, on-device)
- **LLM summarization** — Ollama (local), OpenAI, or Anthropic
- **Custom summary profiles** — swap in a different prompt per session without touching config
- **Native SwiftUI menubar app** — start/stop recording from the menu bar, session browser, settings UI
- **CLI** — scriptable pipeline (`record`, `transcribe`, `summarize`, `run`)
- **Obsidian plugin** — auto-imports sessions into your vault as notes

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Audio capture | [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) (Swift) |
| Transcription | [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML, on-device) |
| Diarization | [SpeakerKit](https://github.com/argmaxinc/WhisperKit) (Pyannote, on-device) |
| Summarization | [Ollama](https://ollama.ai) (local), [OpenAI](https://openai.com), [Anthropic](https://anthropic.com) |
| GUI | Native SwiftUI menubar app |
| CLI | Swift + [ArgumentParser](https://github.com/apple/swift-argument-parser) |
| Credentials | macOS Keychain (API keys stored securely per-service) |

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon (arm64)

## Install

**Homebrew (recommended):**

```bash
brew tap moshebe/pkg
brew install transcribeer
```

**From source:**

```bash
git clone https://github.com/moshebe/transcribeer.git
cd transcribeer
make dev        # builds capture-bin + GUI, registers as a launch agent
```

## Running Permanently (auto-start on login)

```bash
brew services start transcribeer
```

To stop auto-start:

```bash
brew services stop transcribeer
```

## First Run

On first transcription, WhisperKit and SpeakerKit models (~1.5 GB total) are downloaded automatically to `~/.transcribeer/models/`. This is a one-time download.

## GUI

```bash
make gui        # build release + launch the menubar app
make logs       # stream live logs
```

Click the menubar icon to start/stop recording. The full pipeline (record → transcribe → summarize) runs automatically based on your `pipeline.mode` config.

## CLI

```bash
transcribeer run                       # record → transcribe → summarize
transcribeer run --duration 300        # auto-stop after 5 min
transcribeer run --lang he             # force Hebrew transcription
transcribeer run --no-diarize          # skip speaker labels
transcribeer run --no-summarize        # transcript only
transcribeer run --profile standup     # use a custom summary profile

transcribeer record                    # record until Ctrl+C
transcribeer record --duration 60      # record 60 seconds

transcribeer transcribe audio.wav      # transcribe an existing file
transcribeer transcribe audio.wav --lang he --out transcript.txt

transcribeer summarize transcript.txt  # summarize a transcript
transcribeer summarize transcript.txt --backend openai --profile meeting
```

## Configuration

Config is stored at `~/.transcribeer/config.toml`:

```toml
[pipeline]
mode = "record+transcribe+summarize"   # record-only | record+transcribe | record+transcribe+summarize
zoom_auto_record = false               # auto-start when a Zoom meeting is detected

[transcription]
language = "auto"                      # auto, he, en, etc.
model = "openai_whisper-large-v3_turbo"
diarization = "pyannote"              # pyannote | none
num_speakers = 0                      # 0 = auto-detect

[summarization]
backend = "ollama"                    # ollama | openai | anthropic
model = "llama3"
ollama_host = "http://localhost:11434"
prompt_on_stop = true

[paths]
sessions_dir = "~/.transcribeer/sessions"
capture_bin = "~/.transcribeer/bin/capture-bin"
```

### API Keys

API keys for OpenAI and Anthropic are stored in the **macOS Keychain** — never in the config file. Enter them once via **Settings** in the menubar app; they are saved securely and retrieved automatically.

## Summary Profiles

A profile is a Markdown file with a custom system prompt. Profiles let you get different summary styles without changing global config.

```bash
mkdir -p ~/.transcribeer/prompts
cat > ~/.transcribeer/prompts/standup.md <<'EOF'
Summarize this meeting as a concise standup update:
- What was discussed
- Decisions made
- Action items and owners
EOF
```

Use with `--profile standup` in the CLI, or select in the menubar app's Profile menu.

## Obsidian Plugin

The plugin watches `~/.transcribeer/sessions/` and auto-imports new sessions into your vault as notes with YAML frontmatter and a collapsible transcript.

```bash
make obsidian-plugin OBSIDIAN_VAULT="/path/to/your/vault"
```

Then in Obsidian: **Settings → Community Plugins → enable Transcribeer**.

Each imported note includes:
- Date, tags, and source path in frontmatter
- The LLM summary as the note body
- The full transcript in a collapsible callout block

## Building from Source

```bash
make capture        # build capture-bin → ~/.transcribeer/bin/
make gui-build      # build Swift GUI binary
make build-dev      # assemble .app bundle
make gui            # build + launch
make dev            # full dev install (capture + GUI + launch agent)
make obsidian-plugin OBSIDIAN_VAULT=~/path/to/vault
```

## Recording Consent

> **You are solely responsible for complying with all applicable laws and regulations regarding the recording of conversations in your jurisdiction.** Many jurisdictions require the consent of all parties before a conversation may be recorded. Always obtain necessary consent before recording any meeting or call. The authors of this software accept no liability for misuse.

## License

MIT — see [LICENSE](LICENSE).
