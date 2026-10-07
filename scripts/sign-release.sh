#!/bin/bash
set +x
set -euo pipefail
KEY="${SPARKLE_PRIVATE_KEY:?Missing SPARKLE_PRIVATE_KEY}"
export -n KEY
unset SPARKLE_PRIVATE_KEY
cd "$(dirname "$0")/.."
: "${VERSION:?Set VERSION to major.minor.patch}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid release version" >&2; exit 1; }
TOOLS="${1:-$PWD/.build/artifacts/sparkle/Sparkle/bin}"
APP="$PWD/dist/Mergeport.app"
ARCHIVE="dist/release/Mergeport-$VERSION.zip"
test -s "$ARCHIVE" || { echo "Release archive is missing" >&2; exit 1; }
[ ! -e "-" ] && [ ! -L "-" ] || { echo "Remove the unexpected file named '-' before signing." >&2; exit 1; }
ACTUAL="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[ "$VERSION" = "$ACTUAL" ] || { echo "Release version does not match bundle version" >&2; exit 1; }
printf '%s' "$KEY" |
    swift scripts/verify-sparkle-key.swift "$TOOLS/sign_update" \
        Resources/Info.plist "$APP/Contents/Info.plist"
printf '%s' "$KEY" |
    "$TOOLS/generate_appcast" --ed-key-file - \
        --download-url-prefix "https://github.com/wouterdebie/mergeport/releases/download/v$VERSION/" \
        --maximum-deltas 0 dist/release
test -s dist/release/appcast.xml
SIGNATURE="$(xmllint --xpath 'string(/rss/channel/item/enclosure/@*[local-name()="edSignature"])' dist/release/appcast.xml)"
test -n "$SIGNATURE"
printf '%s' "$KEY" |
    "$TOOLS/sign_update" --ed-key-file - --verify dist/release/appcast.xml
printf '%s' "$KEY" |
    "$TOOLS/sign_update" --ed-key-file - --verify "$ARCHIVE" "$SIGNATURE"
unset KEY
