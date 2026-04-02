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
| Credentials | macOS Keychain |

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon (arm64) — Intel builds require compiling the Swift capture binary from source
- [Homebrew](https://brew.sh)

## Install

```bash
brew tap moshebeladev/transcribeer
brew install transcribeer
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

## Building from Source

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Recording Consent

> **You are solely responsible for complying with all applicable laws and regulations regarding the recording of conversations in your jurisdiction.** Many jurisdictions require the consent of all parties before a conversation may be recorded. Always obtain necessary consent before recording any meeting or call. The authors of this software accept no liability for misuse.

## License

MIT — see [LICENSE](LICENSE).
