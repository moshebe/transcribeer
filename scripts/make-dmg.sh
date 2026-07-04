#!/usr/bin/env bash
# make-dmg.sh — Package Transcribeer.app into a distributable DMG.
#
# USAGE:
#   scripts/make-dmg.sh [--app <path>] [--output-dir <dir>] [--version <x.y.z>]
#
# Defaults:
#   --app         gui/.build/Transcribeer.app
#   --output-dir  dist/
#   --version     read from gui/Info.plist CFBundleShortVersionString
#
# OUTPUT:
#   dist/Transcribeer-<version>.dmg
#   Prints SHA-256 at the end — paste into Casks/transcribeer.rb.

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$REPO_ROOT/gui/.build/Transcribeer.app"
OUTPUT_DIR="$REPO_ROOT/dist"
VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)        APP_PATH="$2";   shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --version)    VERSION="$2";    shift 2 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Resolve version
# ---------------------------------------------------------------------------

if [[ -z "$VERSION" ]]; then
    PLIST="$REPO_ROOT/gui/Info.plist"
    if [[ ! -f "$PLIST" ]]; then
        echo "ERROR: could not find gui/Info.plist to read version. Pass --version x.y.z." >&2
        exit 1
    fi
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST" 2>/dev/null \
              || /usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST" 2>/dev/null)
    if [[ -z "$VERSION" ]]; then
        echo "ERROR: no CFBundleShortVersionString or CFBundleVersion in $PLIST. Pass --version x.y.z." >&2
        exit 1
    fi
fi

DMG_NAME="Transcribeer-${VERSION}.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"

# ---------------------------------------------------------------------------
# Validate app bundle
# ---------------------------------------------------------------------------

if [[ ! -d "$APP_PATH" ]]; then
    echo "ERROR: app bundle not found at $APP_PATH" >&2
    echo "       Run 'make build-release' first." >&2
    exit 1
fi

echo "==> Packaging $APP_PATH → $DMG_PATH"
echo "    version: $VERSION"

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Staging folder
# ---------------------------------------------------------------------------

STAGING=$(mktemp -d /tmp/transcribeer-dmg-staging.XXXXXX)
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP_PATH" "$STAGING/Transcribeer.app"
# Applications symlink for drag-to-install UX
ln -s /Applications "$STAGING/Applications"

# ---------------------------------------------------------------------------
# Build DMG — prefer create-dmg for nicer presentation, fall back to hdiutil
# ---------------------------------------------------------------------------

rm -f "$DMG_PATH"

if command -v create-dmg &>/dev/null; then
    echo "==> Using create-dmg for prettier DMG..."
    create-dmg \
        --volname "Transcribeer $VERSION" \
        --volicon "$APP_PATH/Contents/Resources/AppIcon.icns" \
        --window-pos 200 120 \
        --window-size 560 340 \
        --icon-size 128 \
        --icon "Transcribeer.app" 140 160 \
        --hide-extension "Transcribeer.app" \
        --app-drop-link 420 160 \
        --no-internet-enable \
        "$DMG_PATH" \
        "$STAGING/" 2>/dev/null || {
            echo "==> create-dmg failed; falling back to hdiutil..."
            _use_hdiutil=1
        }
else
    _use_hdiutil=1
fi

if [[ "${_use_hdiutil:-0}" == "1" ]]; then
    echo "==> Using hdiutil..."
    # Estimate size: app size + 20 MB overhead
    APP_SIZE_KB=$(du -sk "$STAGING" | awk '{print $1}')
    DMG_SIZE_KB=$((APP_SIZE_KB + 20480))

    TEMP_DIR=$(mktemp -d /tmp/transcribeer-tmp.XXXXXX)
    TEMP_DMG="$TEMP_DIR/tmp.dmg"
    trap 'rm -rf "$STAGING" "$TEMP_DIR"' EXIT

    hdiutil create -srcfolder "$STAGING" \
        -volname "Transcribeer $VERSION" \
        -fs HFS+ \
        -fsargs "-c c=64,a=16,b=16" \
        -format UDRW \
        -size "${DMG_SIZE_KB}k" \
        "$TEMP_DMG" >/dev/null

    hdiutil convert "$TEMP_DMG" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -o "$DMG_PATH" >/dev/null
fi

# ---------------------------------------------------------------------------
# SHA-256
# ---------------------------------------------------------------------------

SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
SIZE=$(du -sh "$DMG_PATH" | awk '{print $1}')

echo ""
echo "==> Done!"
echo "    $DMG_PATH  ($SIZE)"
echo ""
echo "    SHA-256: $SHA256"
echo ""
echo "==> Cask snippet for Casks/transcribeer.rb:"
echo ""
cat <<EOF
  version "$VERSION"
  sha256 "$SHA256"
  url "https://github.com/moshebe/transcribeer/releases/download/v#{version}/Transcribeer-#{version}.dmg"
EOF
