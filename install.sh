#!/usr/bin/env bash
set -euo pipefail

TRANSCRIBEE_DIR="$HOME/.transcribee"
BIN_DIR="$TRANSCRIBEE_DIR/bin"
VENV="$TRANSCRIBEE_DIR/venv"
LOCAL_BIN="$HOME/.local/bin"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok()   { echo "[✓] $*"; }
fail() { echo "[✗] $*" >&2; exit 1; }
info() { echo "    $*"; }

echo "=== Transcribee Installer ==="
echo ""

# ── 1. macOS version ──────────────────────────────────────────────────────────
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[[ "$MACOS_MAJOR" -ge 13 ]] || fail "macOS 13 (Ventura) or later required. Found: $(sw_vers -productVersion)"
ok "macOS $(sw_vers -productVersion)"

# ── 2. Architecture ───────────────────────────────────────────────────────────
ARCH=$(uname -m)
if [[ "$ARCH" != "arm64" ]]; then
  echo ""
  echo "[!] Warning: capture-bin is built for arm64 (Apple Silicon)."
  echo "    Your machine appears to be: $ARCH"
  echo "    To build from source: cd '$REPO_DIR/capture' && swift build -c release"
  echo "    Then copy .build/release/capture to $BIN_DIR/capture-bin"
  echo ""
fi

# ── 3. ffmpeg ─────────────────────────────────────────────────────────────────
if ! command -v ffmpeg &>/dev/null; then
  echo "[!] ffmpeg not found."
  if command -v brew &>/dev/null; then
    read -r -p "    Install via Homebrew? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || fail "ffmpeg is required. Install with: brew install ffmpeg"
    brew install ffmpeg
  else
    fail "ffmpeg is required. Install with: brew install ffmpeg"
  fi
fi
ok "ffmpeg $(ffmpeg -version 2>&1 | head -1 | awk '{print $3}')"

# ── 4. Place capture-bin ──────────────────────────────────────────────────────
mkdir -p "$BIN_DIR"
cp "$REPO_DIR/capture-bin" "$BIN_DIR/capture-bin"
chmod +x "$BIN_DIR/capture-bin"
# Sign with entitlements required by ScreenCaptureKit on macOS 14+
ENTITLEMENTS="$REPO_DIR/capture/capture.entitlements.plist"
if command -v codesign &>/dev/null && [[ -f "$ENTITLEMENTS" ]]; then
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BIN_DIR/capture-bin" 2>/dev/null || true
fi
ok "capture-bin installed → $BIN_DIR/capture-bin"

# ── 5. GUI app ────────────────────────────────────────────────────────────────
APP_DEST="/Applications/Transcribee.app"
APP_BIN="$REPO_DIR/gui/.build/release/TranscribeeMenuBar"
ENTITLEMENTS="$REPO_DIR/capture/capture.entitlements.plist"

# Build if binary is missing or source is newer
if [[ ! -f "$APP_BIN" ]] || [[ "$REPO_DIR/gui/Sources" -nt "$APP_BIN" ]]; then
  echo "    Building GUI..."
  (cd "$REPO_DIR/gui" && swift build -c release -q) || fail "GUI build failed"
fi

mkdir -p "$APP_DEST/Contents/MacOS"
cp "$APP_BIN" "$APP_DEST/Contents/MacOS/TranscribeeMenuBar"
cp "$REPO_DIR/gui/Info.plist" "$APP_DEST/Contents/"
chmod +x "$APP_DEST/Contents/MacOS/TranscribeeMenuBar"

# Sign (ad-hoc is fine for personal use)
if command -v codesign &>/dev/null; then
  codesign --force --sign - "$APP_DEST" 2>/dev/null || true
fi
ok "Transcribee.app installed → $APP_DEST"

# ── 6. Python venv ────────────────────────────────────────────────────────────
if ! command -v uv &>/dev/null; then
  echo "[!] uv not found — installing..."
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
ok "uv $(uv --version)"

uv python install 3.11 --quiet
uv venv "$VENV" --python 3.11 --quiet
ok "Python venv → $VENV"

source "$VENV/bin/activate"

uv pip install -q faster-whisper torch torchaudio typer rich requests openai anthropic

# ── 7. Diarization backend ────────────────────────────────────────────────────
echo ""
echo "Speaker diarization — choose backend:"
echo "  (A) pyannote   — best quality, requires HuggingFace account"
echo "  (B) resemblyzer — no account needed, good quality"
echo "  (N) none       — no speaker labels, fastest"
echo ""
read -r -p "Choice [A/B/N]: " diar_choice

DIARIZATION="none"
case "$(echo "$diar_choice" | tr '[:lower:]' '[:upper:]')" in
  A)
    uv pip install -q pyannote.audio
    DIARIZATION="pyannote"
    echo ""
    echo "  HuggingFace token needed."
    echo "  1. Create account at https://huggingface.co"
    echo "  2. Accept model terms at https://huggingface.co/ivrit-ai/pyannote-speaker-diarization-3.1"
    echo "  3. Create a token at https://huggingface.co/settings/tokens (read permission)"
    echo ""
    read -r -p "  Paste your HF token: " hf_token
    mkdir -p "$HOME/.cache/huggingface"
    echo "$hf_token" > "$HOME/.cache/huggingface/token"
    chmod 600 "$HOME/.cache/huggingface/token"
    # Validate
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer $hf_token" \
      "https://huggingface.co/api/whoami" || echo "000")
    if [[ "$http_code" == "200" ]]; then
      ok "HuggingFace token valid"
    else
      echo "[!] Token validation returned HTTP $http_code — continuing anyway."
      echo "    If model download fails, check your token and model terms acceptance."
    fi
    ;;
  B)
    uv pip install -q resemblyzer scikit-learn
    DIARIZATION="resemblyzer"
    ok "resemblyzer installed"
    ;;
  *)
    DIARIZATION="none"
    ok "Skipping diarization"
    ;;
esac

# ── 8. Install transcribee package ───────────────────────────────────────────
uv pip install -q -e "$REPO_DIR"
ok "transcribee package installed"

# ── 9. Write config ───────────────────────────────────────────────────────────
mkdir -p "$TRANSCRIBEE_DIR/sessions"
CONFIG_FILE="$TRANSCRIBEE_DIR/config.toml"

if [[ ! -f "$CONFIG_FILE" ]]; then
  cat > "$CONFIG_FILE" <<TOML
[transcription]
language = "auto"
diarization = "$DIARIZATION"
num_speakers = 0

[summarization]
backend = "ollama"
model = "llama3"
ollama_host = "http://localhost:11434"

[paths]
sessions_dir = "~/.transcribee/sessions"
capture_bin = "~/.transcribee/bin/capture-bin"
TOML
  ok "Config written → $CONFIG_FILE"
else
  info "Config already exists at $CONFIG_FILE — not overwritten"
fi

# ── 10. PATH setup ────────────────────────────────────────────────────────────
mkdir -p "$LOCAL_BIN"
ln -sf "$VENV/bin/transcribee" "$LOCAL_BIN/transcribee"
ok "Symlink: $LOCAL_BIN/transcribee → $VENV/bin/transcribee"

if [[ ":$PATH:" != *":$LOCAL_BIN:"* ]]; then
  case "$SHELL" in
    */zsh)  SHELL_RC="$HOME/.zshrc" ;;
    */bash) SHELL_RC="$HOME/.bashrc" ;;
    */fish) SHELL_RC="$HOME/.config/fish/config.fish" ;;
    *)      SHELL_RC="$HOME/.profile" ;;
  esac
  echo "" >> "$SHELL_RC"
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
  echo ""
  echo "[✓] Added ~/.local/bin to PATH in $SHELL_RC"
  echo "    Run: source $SHELL_RC   (or restart your terminal)"
fi

echo ""
echo "=== Installation complete ==="
echo ""
echo "Usage:"
echo "  transcribee run --duration 300    # record 5 min, transcribe, summarize"
echo "  transcribee record                # record until Ctrl+C"
echo "  transcribee transcribe audio.wav  # transcribe existing file"
echo "  transcribee --help                # all commands"
echo ""
echo "  To launch: open /Applications/Transcribee.app"
echo "  To auto-start on login: add it in System Settings → General → Login Items"
echo ""
