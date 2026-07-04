#!/usr/bin/env bash
# publish-ivrit-coreml.sh — Convert ivrit.ai Whisper models to CoreML and prepare
# a GitHub Release upload command.
#
# USAGE:
#   scripts/publish-ivrit-coreml.sh [--output-dir <dir>]
#
# After writing this file, make it executable:
#   chmod +x scripts/publish-ivrit-coreml.sh
#
# PREREQUISITES:
#   1. whisperkit-generate-model
#      Install via whisperkittools:
#        pip install whisperkittools
#      Or via the repo at https://github.com/argmaxinc/whisperkittools
#
#   2. gh (GitHub CLI)
#      Install via Homebrew:  brew install gh
#      Then authenticate:     gh auth login
#
#   3. HuggingFace token with read access to ivrit-ai org
#      Set:  huggingface-cli login
#      Or:   export HF_TOKEN=<your-token>

set -euo pipefail

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------

if ! command -v whisperkit-generate-model &>/dev/null; then
    echo "ERROR: whisperkit-generate-model not found on PATH." >&2
    echo "" >&2
    echo "Install it via:" >&2
    echo "  pip install whisperkittools" >&2
    echo "  # or set up a venv:" >&2
    echo "  python3 -m venv whisperkittools && source whisperkittools/bin/activate && pip install whisperkittools" >&2
    exit 1
fi

if ! command -v gh &>/dev/null; then
    echo "ERROR: gh (GitHub CLI) not found on PATH." >&2
    echo "" >&2
    echo "Install it via:" >&2
    echo "  brew install gh" >&2
    echo "  gh auth login" >&2
    exit 1
fi

if ! command -v shasum &>/dev/null; then
    echo "ERROR: shasum not found. Expected on macOS by default." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

OUTPUT_DIR="./dist/models"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "USAGE: $0 [--output-dir <dir>]" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

echo "==> Output directory: $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

TURBO_NAME="ivrit-ai_whisper-large-v3-turbo"
LARGE_NAME="ivrit-ai_whisper-large-v3"

TURBO_DIR="$OUTPUT_DIR/$TURBO_NAME"
LARGE_DIR="$OUTPUT_DIR/$LARGE_NAME"

TURBO_TAR="$OUTPUT_DIR/$TURBO_NAME.tar.zst"
LARGE_TAR="$OUTPUT_DIR/$LARGE_NAME.tar.zst"

# ---------------------------------------------------------------------------
# Convert models
# ---------------------------------------------------------------------------

echo ""
echo "==> Converting ivrit-ai/whisper-large-v3-turbo ..."
whisperkit-generate-model \
    --model-version "ivrit-ai/whisper-large-v3-turbo" \
    --output-dir "$TURBO_DIR"

echo ""
echo "==> Converting ivrit-ai/whisper-large-v3 ..."
whisperkit-generate-model \
    --model-version "ivrit-ai/whisper-large-v3" \
    --output-dir "$LARGE_DIR"

# ---------------------------------------------------------------------------
# Package: tar + zstd
# ---------------------------------------------------------------------------

echo ""
echo "==> Packaging $TURBO_NAME.tar.zst ..."
tar --zstd -cf "$TURBO_TAR" -C "$OUTPUT_DIR" "$TURBO_NAME"

echo "==> Packaging $LARGE_NAME.tar.zst ..."
tar --zstd -cf "$LARGE_TAR" -C "$OUTPUT_DIR" "$LARGE_NAME"

# ---------------------------------------------------------------------------
# SHA-256 checksums
# ---------------------------------------------------------------------------

echo ""
echo "==> SHA-256 checksums:"
TURBO_SHA=$(shasum -a 256 "$TURBO_TAR" | awk '{print $1}')
LARGE_SHA=$(shasum -a 256 "$LARGE_TAR" | awk '{print $1}')

echo "  $TURBO_NAME.tar.zst  $TURBO_SHA"
echo "  $LARGE_NAME.tar.zst  $LARGE_SHA"

# ---------------------------------------------------------------------------
# Print gh release command (do NOT execute)
# ---------------------------------------------------------------------------

echo ""
echo "==> Run this command to publish (review before executing):"
echo ""
cat <<EOF
gh release create models-v1 \\
    --repo moshebe/transcribeer \\
    --title "Models v1" \\
    --notes "CoreML-converted Hebrew Whisper models from ivrit.ai. Apache-2.0." \\
    "$TURBO_TAR" \\
    "$LARGE_TAR"
EOF

# ---------------------------------------------------------------------------
# Instructions for updating ModelManifest.swift
# ---------------------------------------------------------------------------

echo ""
echo "==> Now update gui/Sources/TranscribeerCore/ModelManifest.swift with these SHA-256 values:"
echo ""
echo "  hebrewTurbo:"
echo "    sha256: \"$TURBO_SHA\""
echo ""
echo "  hebrewLarge:"
echo "    sha256: \"$LARGE_SHA\""
echo ""
echo "Replace the __PENDING__ placeholders, rebuild, and ship a new app version."
echo ""
echo "Done. Tarballs are at:"
echo "  $TURBO_TAR"
echo "  $LARGE_TAR"
