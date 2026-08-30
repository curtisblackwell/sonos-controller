#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SonosController"
APP_DIR="$ROOT_DIR/$APP_NAME.app"
BUNDLE_ID="com.curtisblackwell.sonos-controller"

cd "$ROOT_DIR"

# Per-developer config (SPOTIFY_CLIENT_ID, ...) without needing it exported in the shell
# profile - .env is gitignored, so this stays out of the repo.
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp ".build/release/SonosMenuBar" "$APP_DIR/Contents/MacOS/$APP_NAME"

# SPOTIFY_CLIENT_ID is never committed to Info.plist - it's substituted in here from the
# environment, empty for anyone who hasn't set one, which just leaves Spotify auth
# unconfigured rather than shipping a real client id in source.
sed "s/__SPOTIFY_CLIENT_ID__/${SPOTIFY_CLIENT_ID:-}/" "Resources/Info.plist" > "$APP_DIR/Contents/Info.plist"

# Prefer the stable local dev certificate (see Scripts/setup-dev-cert.sh) over ad-hoc
# signing - ad-hoc gets a new identity every rebuild, which makes macOS silently drop
# the Accessibility grant each time. Falls back to ad-hoc if the cert isn't installed.
# Note: self-signed certs are untrusted (CSSMERR_TP_NOT_TRUSTED), so `-v` (valid-only)
# hides it - drop -v, and match by SHA-1 hash rather than name for reliable signing.
SIGN_IDENTITY=$(security find-identity -p codesigning 2>/dev/null | grep -F "SonosController Local Dev" | awk '{print $2}' | head -1) || true
if [ -z "$SIGN_IDENTITY" ]; then
    echo "Note: no stable dev signing identity found, using ad-hoc (run Scripts/setup-dev-cert.sh once to fix)."
    SIGN_IDENTITY="-"
fi

codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_DIR"

echo "Built $APP_DIR (signed with: $SIGN_IDENTITY)"

open $APP_DIR
