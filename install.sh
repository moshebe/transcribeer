#!/usr/bin/env bash
set -euo pipefail

# Non-interactive mode (used by Homebrew formula)
NONINTERACTIVE="${TRANSCRIBEER_NONINTERACTIVE:-0}"

ask_yn() {
  local prompt="$1" default="${2:-N}"
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    [[ "$default" == "Y" ]] && return 0 || return 1
  fi
  read -r -p "$prompt" yn
  [[ "$yn" =~ ^[Yy]$ ]]
}

TRANSCRIBEE_DIR="$HOME/.transcribeer"
BIN_DIR="$TRANSCRIBEE_DIR/bin"
VENV="$TRANSCRIBEE_DIR/venv"
LOCAL_BIN="$HOME/.local/bin"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok()   { echo "[✓] $*"; }
fail() { echo "[✗] $*" >&2; exit 1; }
info() { echo "    $*"; }

echo "=== Transcribeer Installer ==="
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
    if ask_yn "    Install via Homebrew? [y/N] "; then
      brew install ffmpeg
    else
      fail "ffmpeg is required. Install with: brew install ffmpeg"
    fi
  else
    fail "ffmpeg is required. Install with: brew install ffmpeg"
  fi
fi
ok "ffmpeg $(ffmpeg -version 2>&1 | head -1 | awk '{print $3}')"

# ── 4. Place capture-bin ──────────────────────────────────────────────────────
mkdir -p "$BIN_DIR"
cp "$REPO_DIR/capture-bin" "$BIN_DIR/capture-bin"
chmod +x "$BIN_DIR/capture-bin"
ENTITLEMENTS="$REPO_DIR/capture/capture.entitlements.plist"
if command -v codesign &>/dev/null && ! codesign --verify "$BIN_DIR/capture-bin" 2>/dev/null; then
  [[ -f "$ENTITLEMENTS" ]] && codesign --sign - --entitlements "$ENTITLEMENTS" "$BIN_DIR/capture-bin" 2>/dev/null || true
fi
ok "capture-bin installed → $BIN_DIR/capture-bin"

# ── 5. Python venv ────────────────────────────────────────────────────────────
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

uv pip install -q faster-whisper torch torchaudio typer rich requests openai anthropic rumps

# ── 6. Diarization backend ────────────────────────────────────────────────────
echo ""
echo "Speaker diarization — choose backend:"
echo "  (A) pyannote    — best quality, requires HuggingFace account"
echo "  (B) resemblyzer — no account needed, good quality"
echo "  (N) none        — no speaker labels, fastest"
echo ""

if [[ "$NONINTERACTIVE" == "1" ]]; then
  diar_choice="B"
  echo "    [non-interactive] defaulting to resemblyzer"
else
  read -r -p "Choice [A/B/N]: " diar_choice
fi

DIARIZATION="none"
case "$(echo "$diar_choice" | tr '[:lower:]' '[:upper:]')" in
  A)
    uv pip install -q pyannote.audio
    DIARIZATION="pyannote"
    if [[ "$NONINTERACTIVE" != "1" ]]; then
      echo ""
      echo "  HuggingFace token needed."
      echo "  1. Create account at https://huggingface.co"
      echo "  2. Accept model terms: https://huggingface.co/ivrit-ai/pyannote-speaker-diarization-3.1"
      echo "  3. Create a token at https://huggingface.co/settings/tokens (read permission)"
      echo ""
      read -r -p "  Paste your HF token: " hf_token
      mkdir -p "$HOME/.cache/huggingface"
      echo "$hf_token" > "$HOME/.cache/huggingface/token"
      chmod 600 "$HOME/.cache/huggingface/token"
      http_code=$(curl -sf -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $hf_token" \
        "https://huggingface.co/api/whoami" || echo "000")
      if [[ "$http_code" == "200" ]]; then
        ok "HuggingFace token valid"
      else
        echo "[!] Token validation returned HTTP $http_code — continuing anyway."
      fi
    else
      echo "    [non-interactive] pyannote selected but HF token not set — run: transcribeer config"
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

# ── 7. Install transcribeer package ───────────────────────────────────────────
uv pip install -q -e "$REPO_DIR[gui]"
ok "transcribeer package installed"

# ── 8. Write config ───────────────────────────────────────────────────────────
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
sessions_dir = "~/.transcribeer/sessions"
capture_bin = "~/.transcribeer/bin/capture-bin"
TOML
  ok "Config written → $CONFIG_FILE"
else
  info "Config already exists at $CONFIG_FILE — not overwritten"
fi

# ── 9. PATH setup ─────────────────────────────────────────────────────────────
mkdir -p "$LOCAL_BIN"
ln -sf "$VENV/bin/transcribeer" "$LOCAL_BIN/transcribeer"
ln -sf "$VENV/bin/transcribeer-gui" "$LOCAL_BIN/transcribeer-gui"
ok "Symlinks → $LOCAL_BIN/{transcribeer,transcribeer-gui}"

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
echo "  transcribeer-gui                   # launch menubar app"
echo "  transcribeer run --duration 300    # record 5 min, transcribe, summarize (CLI)"
echo "  transcribeer record                # record until Ctrl+C"
echo "  transcribeer transcribe audio.wav  # transcribe existing file"
echo "  transcribeer --help                # all commands"
echo ""
