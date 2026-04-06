<div align="center">
  <img src="assets/logo-readme.png" width="120" alt="Transcribeer logo"/>
  <h1>Transcribeer 🍺</h1>
  <p><strong>Local-first meeting transcription and summarization for macOS</strong></p>
  <p>
    <img src="https://img.shields.io/badge/macOS-13%2B-blue?logo=apple" alt="macOS 13+"/>
    <img src="https://img.shields.io/badge/Apple_Silicon-arm64-green" alt="Apple Silicon"/>
    <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"/>
  </p>
</div>

---

Transcribeer captures both sides of any call, transcribes with speaker labels, and optionally summarizes with an LLM — all running locally on your Mac. No cloud required.

## Features

- **System audio capture** — records both microphone and speaker audio via Apple ScreenCaptureKit
- **Local transcription** — [faster-whisper](https://github.com/SYSTRAN/faster-whisper) + [ivrit-ai](https://huggingface.co/ivrit-ai) model, optimised for Hebrew and English
- **Speaker diarization** — who said what, via [pyannote.audio](https://github.com/pyannote/pyannote-audio) or [resemblyzer](https://github.com/resemble-ai/Resemblyzer)
- **LLM summarization** — Ollama (local), OpenAI, or Anthropic
- **Custom summary profiles** — swap in a different prompt per session without touching config
- **Native macOS menubar app** — start/stop recording from the menu bar, session browser, settings UI
- **CLI** — scriptable, composable pipeline (`record → transcribe → summarize`)

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Audio capture | [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) (Swift) |
| Transcription | [faster-whisper](https://github.com/SYSTRAN/faster-whisper) + [ivrit-ai model](https://huggingface.co/ivrit-ai) |
| Diarization | [pyannote.audio](https://github.com/pyannote/pyannote-audio) / [resemblyzer](https://github.com/resemble-ai/Resemblyzer) |
| Summarization | [Ollama](https://ollama.ai) (local), [OpenAI](https://openai.com), [Anthropic](https://anthropic.com) |
| GUI | [rumps](https://github.com/jaredks/rumps) (menubar) + WKWebView (native windows) |
| Credentials | macOS Keychain (API keys stored securely per-service) |

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon (arm64) — Intel builds require compiling the Swift capture binary from source
- [Homebrew](https://brew.sh)

## Install

**Homebrew (recommended):**

```bash
brew tap moshebe/transcribeer https://github.com/moshebe/transcribeer
brew install moshebe/transcribeer/transcribeer
```

**Without Homebrew — via [uv](https://github.com/astral-sh/uv):**

```bash
uv tool install "transcribeer[gui,resemblyzer,openai,anthropic]"
```

Then copy `capture-bin` to `~/.transcribeer/bin/capture-bin` and set
`capture_bin` in `~/.transcribeer/config.toml` (see Configuration below).

## Running Permanently (auto-start on login)

```bash
brew services start moshebe/transcribeer/transcribeer
```

This registers the menubar app as a launchd service so it launches automatically when you log in. To stop auto-start:

```bash
brew services stop moshebe/transcribeer/transcribeer
```

## First Run

```bash
transcribeer-gui          # launch the menubar app (recommended)
transcribeer --help       # CLI usage
```

The first transcription will automatically download the Whisper model (~1.5 GB). This is a one-time download.

## CLI Usage

```bash
transcribeer run --duration 300        # record 5 min, transcribe, summarize
transcribeer record                    # record until Ctrl+C
transcribeer transcribe audio.wav      # transcribe an existing file
transcribeer summarize session.txt     # summarize a transcript
transcribeer summarize session.txt --profile meeting   # use a custom profile
```

## Configuration

Config is stored at `~/.transcribeer/config.toml`:

```toml
[transcription]
language = "auto"           # auto, he, en
diarization = "resemblyzer" # pyannote, resemblyzer, none
num_speakers = 0            # 0 = auto-detect

[summarization]
backend = "ollama"          # ollama, openai, anthropic
model = "llama3"
ollama_host = "http://localhost:11434"
```

### API Keys

API keys for OpenAI and Anthropic are stored in the **macOS Keychain** — never in the config file. Enter them once via **Settings** in the menubar app; they are saved securely and retrieved automatically on each run.

## Summary Profiles

A profile is a Markdown file containing a custom system prompt. Profiles let you get different summary styles (e.g. bullet-point action items vs. a narrative recap) without changing the global config.

**Create a profile:**

```bash
mkdir -p ~/.transcribeer/prompts
cat > ~/.transcribeer/prompts/standup.md <<'EOF'
Summarize this meeting as a concise standup update:
- What was discussed
- Decisions made
- Action items and owners
EOF
```

**Use a profile:**

- **Menubar**: click **Profile** in the menu during or after a recording and type the profile name
- **CLI**: pass `--profile standup` to `transcribeer summarize` or `transcribeer run`

The built-in default prompt is used when no profile is selected. Profiles live in `~/.transcribeer/prompts/*.md`; the filename (without `.md`) is the profile name.

## Building from Source

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Recording Consent

> **You are solely responsible for complying with all applicable laws and regulations regarding the recording of conversations in your jurisdiction.** Many jurisdictions require the consent of all parties before a conversation may be recorded. Always obtain necessary consent before recording any meeting or call. The authors of this software accept no liability for misuse.

## License

MIT — see [LICENSE](LICENSE).
