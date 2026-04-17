#!/usr/bin/env bash
# End-to-end Hebrew transcription test.
#
# 1. Starts capture-bin (same binary Transcribeer uses) to record system audio.
# 2. Plays the ivrit.ai 30s Hebrew sample via afplay.
# 3. Transcribes the captured WAV with WhisperKit (default model, same path
#    Transcribeer uses: ~/.transcribeer/models).
# 4. Asks Claude to compare the hypothesis to the reference transcript.
#
# Requirements:
# - capture-bin built + granted Screen Recording TCC for your terminal
#   (Transcribeer captures system audio via ScreenCaptureKit, which taps the
#    default output regardless of selected device, so BlackHole is optional).
# - $ANTHROPIC_API_KEY set.
# - afplay (shipped with macOS).
#
# Environment overrides:
#   CAPTURE_BIN   path to capture-bin              (default: ~/.transcribeer/bin/capture-bin)
#   SAMPLE_WAV    path to the Hebrew sample WAV    (default: repo test-samples/ivrit-ai/sample_30s_he.wav)
#   SAMPLE_TXT    path to the reference transcript (default: alongside SAMPLE_WAV)
#   LANGUAGE      Whisper language hint            (default: he)
#   MODEL         WhisperKit model id              (default: openai_whisper-large-v3_turbo)
#   ARTIFACTS_DIR where to write outputs           (default: tests/e2e/.artifacts)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
E2E_DIR="$REPO_ROOT/tests/e2e"

CAPTURE_BIN="${CAPTURE_BIN:-$HOME/.transcribeer/bin/capture-bin}"
SAMPLE_WAV="${SAMPLE_WAV:-$REPO_ROOT/test-samples/ivrit-ai/sample_30s_he.wav}"
SAMPLE_TXT="${SAMPLE_TXT:-${SAMPLE_WAV%.wav}.txt}"
LANGUAGE="${LANGUAGE:-he}"
MODEL="${MODEL:-openai_whisper-large-v3_turbo}"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$E2E_DIR/.artifacts}"

log() { printf '\033[1;34m[e2e]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[e2e]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$CAPTURE_BIN" ]] || die "capture-bin not found at $CAPTURE_BIN (run: make capture)"
[[ -f "$SAMPLE_WAV" ]]  || die "sample WAV missing: $SAMPLE_WAV"
[[ -f "$SAMPLE_TXT" ]]  || die "sample transcript missing: $SAMPLE_TXT"
[[ -n "${ANTHROPIC_API_KEY:-}" ]] || die "ANTHROPIC_API_KEY not set"
command -v afplay  >/dev/null || die "afplay missing (ships with macOS)"
command -v ffprobe >/dev/null || die "ffprobe missing (brew install ffmpeg)"
command -v swift   >/dev/null || die "swift toolchain missing"
command -v python3 >/dev/null || die "python3 missing"

mkdir -p "$ARTIFACTS_DIR"
CAPTURED_WAV="$ARTIFACTS_DIR/captured.wav"
HYPOTHESIS_TXT="$ARTIFACTS_DIR/hypothesis.txt"
JUDGE_LOG="$ARTIFACTS_DIR/judge.txt"

SAMPLE_DUR="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$SAMPLE_WAV")"
# Add 3s head + tail of silence so capture covers model warm-up and trailing audio.
CAPTURE_DUR="$(python3 -c "import math,sys; print(int(math.ceil(float(sys.argv[1])) + 6))" "$SAMPLE_DUR")"

log "sample      : $SAMPLE_WAV (${SAMPLE_DUR}s)"
log "capture bin : $CAPTURE_BIN"
log "output wav  : $CAPTURED_WAV"
log "capture dur : ${CAPTURE_DUR}s"

# ── build transcribe-cli (once) ─────────────────────────────────────────────
log "building transcribe-cli…"
(
    cd "$E2E_DIR/TranscribeCLI"
    swift build -c release -q
)
TRANSCRIBE_CLI="$E2E_DIR/TranscribeCLI/.build/release/transcribe-cli"
[[ -x "$TRANSCRIBE_CLI" ]] || die "transcribe-cli build failed"

# ── start capture, play sample, wait ────────────────────────────────────────
rm -f "$CAPTURED_WAV"
log "starting capture-bin…"
"$CAPTURE_BIN" "$CAPTURED_WAV" "$CAPTURE_DUR" 2>"$ARTIFACTS_DIR/capture.log" &
CAPTURE_PID=$!

cleanup() {
    if kill -0 "$CAPTURE_PID" 2>/dev/null; then
        kill -INT "$CAPTURE_PID" 2>/dev/null || true
        wait "$CAPTURE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

# Give ScreenCaptureKit a moment to spin up before playing.
sleep 2

log "playing sample via afplay (you will hear it on the default output)…"
afplay "$SAMPLE_WAV"

# Let capture drain and auto-stop.
log "waiting for capture-bin to finish…"
wait "$CAPTURE_PID" || true
trap - EXIT INT TERM

[[ -s "$CAPTURED_WAV" ]] || die "capture produced no audio — check Screen Recording permission"
CAPTURED_BYTES="$(stat -f%z "$CAPTURED_WAV")"
log "captured $(printf '%.1f' "$(bc <<<"scale=2; $CAPTURED_BYTES/1048576")") MB"

# Sanity: warn if captured clip looks silent.
PEAK="$(ffprobe -v error -f lavfi -i "amovie='$CAPTURED_WAV',astats=metadata=1:reset=1" \
       -show_entries frame_tags=lavfi.astats.Overall.Peak_level \
       -of default=nw=1:nk=1 2>/dev/null | tail -1 || true)"
log "captured peak level: ${PEAK:-unknown} dBFS"

# ── transcribe ──────────────────────────────────────────────────────────────
log "transcribing with $MODEL (language=$LANGUAGE)…"
"$TRANSCRIBE_CLI" "$CAPTURED_WAV" --language "$LANGUAGE" --model "$MODEL" \
    >"$HYPOTHESIS_TXT" 2>"$ARTIFACTS_DIR/transcribe.log"
[[ -s "$HYPOTHESIS_TXT" ]] || die "transcribe-cli produced no output — see $ARTIFACTS_DIR/transcribe.log"

# ── judge with Claude ───────────────────────────────────────────────────────
log "judging quality with Claude…"
set +e
python3 "$E2E_DIR/compare.py" "$SAMPLE_TXT" "$HYPOTHESIS_TXT" | tee "$JUDGE_LOG"
RC=${PIPESTATUS[0]}
set -e

case "$RC" in
    0) log "PASS"   ;;
    1) log "WARN — transcript usable but degraded"   ;;
    2) log "FAIL — transcript quality unacceptable"  ;;
    *) log "compare.py exited $RC" ;;
esac

log "artifacts in $ARTIFACTS_DIR"
exit "$RC"
