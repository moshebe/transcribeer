# Contributing to Transcribeer

Thanks for your interest! Here's how to get set up and contribute.

## Requirements

- macOS 13+ (Ventura or later), Apple Silicon
- [uv](https://github.com/astral-sh/uv) — Python package manager
- Xcode Command Line Tools (for Swift binary): `xcode-select --install`
- [Homebrew](https://brew.sh)

## Dev Setup

```bash
# Clone the repo
git clone https://github.com/moshebe/transcribeer.git
cd transcribeer

# Install Python deps (dev extras)
uv sync --extra dev --extra gui --extra resemblyzer

# Install the package in editable mode
uv pip install -e ".[gui,resemblyzer,dev]"

# Run tests
uv run pytest tests/ -q
```

## Building the Swift Capture Binary

The pre-compiled `capture-bin` in the repo is built for arm64. To rebuild:

```bash
cd capture
swift build -c release
cp .build/release/capture ../capture-bin
# Re-sign with entitlements
codesign --force --sign - --entitlements capture.entitlements.plist ../capture-bin
```

## Running the App

```bash
# Menubar GUI
uv run transcribeer-gui

# CLI
uv run transcribeer --help
```

## Pull Request Guidelines

- Use [conventional commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `chore:`
- One concern per PR — keep diffs focused
- Run `uv run pytest tests/ -q` before opening a PR
- For Swift changes, run the Swift tests: `cd capture && swift test`

## Reporting Issues

Please include:
- macOS version (`sw_vers`)
- Whether you're on Apple Silicon or Intel
- The command you ran and the full error output
