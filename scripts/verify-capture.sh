#!/usr/bin/env bash
# Manual verification of the full capture → mix → transcribe pipeline
# against real audio. Replaces the deleted tests/e2e/hebrew-loopback.sh.
#
# What this covers vs. the automated test suite:
# - `swift test` exercises DualAudioRecorder / AudioMixer / DualSourceTranscriber
#   with synthetic PCM and mocked ML backends, in seconds and with no
#   permission prompts.
# - This script covers what `swift test` *can't*: real CoreAudio process-tap
#   capture, real AVAudioEngine mic capture, real WhisperKit transcription,
#   and the TCC permission prompts that only fire when the actual `.app`
#   bundle records audio.
#
# Usage:
#   make build-dev
#   ./scripts/verify-capture.sh [DURATION_SECONDS]
#
# Prerequisites:
#   - App bundle built (`make build-dev`)
#   - Microphone + System Audio Recording TCC granted to the `.app`
#     (launch it once and click record to trigger the prompts)
#   - A reference WAV in tests/e2e/reference.wav (any speech, any language)
#     or override via REFERENCE_WAV=/path/to/your.wav
#   - afplay available (ships with macOS)

set -euo pipefail

DURATION="${1:-15}"
REFERENCE_WAV="${REFERENCE_WAV:-tests/e2e/reference.wav}"
APP_BUNDLE="gui/.build/Transcribeer.app"
SESSIONS_DIR="$HOME/.transcribeer/sessions"

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "✗ App bundle not found at $APP_BUNDLE — run: make build-dev" >&2
  exit 1
fi

if [[ ! -f "$REFERENCE_WAV" ]]; then
  echo "✗ Reference WAV not found at $REFERENCE_WAV" >&2
  echo "  Provide any speech recording (WAV/M4A) or override REFERENCE_WAV" >&2
  exit 1
fi

echo "→ Recording ${DURATION}s while playing $REFERENCE_WAV through default output"
echo "  (the app must be running and recording; this script plays the audio"
echo "   but the user must click Record in the menu bar first)"
echo ""

# Count sessions before so we can find the new one after.
before_count=$(find "$SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')

# Play the reference audio through the default output. The app's
# SystemAudioCapture (process tap) should capture this; AVAudioEngine mic
# capture grabs whatever the user says (or silence if they don't).
afplay "$REFERENCE_WAV" &
AFPLAY_PID=$!
trap 'kill $AFPLAY_PID 2>/dev/null || true' EXIT

sleep "$DURATION"
kill "$AFPLAY_PID" 2>/dev/null || true
wait "$AFPLAY_PID" 2>/dev/null || true

echo ""
echo "→ Locating new session directory"
sleep 2  # let the pipeline finalize

new_session=""
for dir in "$SESSIONS_DIR"/*/; do
  [[ -d "$dir" ]] || continue
  # Grab the newest session created during/after this run
  if [[ -z "$new_session" ]] || [[ "$dir" -nt "$new_session" ]]; then
    new_session="$dir"
  fi
done

after_count=$(find "$SESSIONS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
if [[ "$after_count" -le "$before_count" ]]; then
  echo "✗ No new session detected under $SESSIONS_DIR" >&2
  echo "  Did you click Record in the app before running this script?" >&2
  exit 1
fi

echo "  Session: $new_session"

# Artifact inventory
echo ""
echo "→ Checking session artifacts"
missing=()
for f in audio.m4a audio.mic.caf audio.sys.caf timing.json; do
  if [[ -f "$new_session$f" ]]; then
    size=$(stat -f%z "$new_session$f")
    echo "  ✓ $f ($size bytes)"
  else
    echo "  ✗ $f missing"
    missing+=("$f")
  fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
  echo ""
  echo "✗ Missing required artifacts: ${missing[*]}" >&2
  exit 1
fi

# Transcript check (the app pipeline writes transcript.txt automatically)
echo ""
if [[ -f "$new_session/transcript.txt" ]]; then
  lines=$(wc -l < "$new_session/transcript.txt" | tr -d ' ')
  echo "→ transcript.txt: $lines lines"
  echo "  First 5:"
  head -5 "$new_session/transcript.txt" | sed 's/^/    /'
else
  echo "✗ transcript.txt missing — pipeline may have errored" >&2
  echo "  Check: $new_session/run.log"
  exit 1
fi

echo ""
echo "✓ Verification complete — full capture → mix → transcribe pipeline works"
echo ""
echo "Manual checks to perform:"
echo "  1. audio.m4a plays back cleanly (Cmd-click → Quick Look)"
echo "  2. Transcript contains recognizable content from the reference audio"
echo "  3. If you spoke during the recording, your speech appears as"
echo "     '${PWD##*/}: …' or the speaker label configured in Settings"
echo "  4. System audio appears with the 'Other' label"
