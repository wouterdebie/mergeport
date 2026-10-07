#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
DEFAULT_APP="$PWD/dist/Mergeport.app"
APP="${1:-$DEFAULT_APP}"
IDENTITY="${CODESIGN_IDENTITY:--}"
EXPECTED_CERT_SHA1="89AFE2B56FFCB7344A7600B5E38E97C68A544591"
ARGS=(--force --sign "$IDENTITY" --preserve-metadata=entitlements)
if [ "$IDENTITY" = "$EXPECTED_CERT_SHA1" ]; then
    ARGS+=(--options runtime --timestamp)
elif [ "$IDENTITY" = "-" ]; then
    echo "Ad-hoc development signing; not suitable for publication." >&2
elif security find-identity -v -p codesigning | grep -F "$IDENTITY" | grep -q '"Apple Development: '; then
    # Local builds only: a stable identity keeps Keychain access across rebuilds.
    ARGS+=(--options runtime)
else
    echo "Use the pinned Developer ID fingerprint, an Apple Development identity, or '-'. Refusing another certificate." >&2
    exit 1
fi
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
VERSION="$FRAMEWORK/Versions/B"
codesign "${ARGS[@]}" "$VERSION/XPCServices/Downloader.xpc"
codesign "${ARGS[@]}" "$VERSION/XPCServices/Installer.xpc"
codesign "${ARGS[@]}" "$VERSION/Autoupdate"
codesign "${ARGS[@]}" "$VERSION/Updater.app"
codesign "${ARGS[@]}" "$FRAMEWORK"
codesign "${ARGS[@]}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
