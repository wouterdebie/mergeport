#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VERSION:?Set VERSION to major.minor.patch}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid release version" >&2; exit 1; }
APP="$PWD/dist/Mergeport.app"
ACTUAL="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[ "$VERSION" = "$ACTUAL" ] || { echo "Release version does not match bundle version" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute "$APP"
OUT="$PWD/dist/release"
mkdir -p "$OUT"
[ ! -e "$OUT/Mergeport-$VERSION.zip" ] || { echo "Release archive already exists" >&2; exit 1; }
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Mergeport-$VERSION.zip"
cd "$OUT"
shasum -a 256 "Mergeport-$VERSION.zip" > "Mergeport-$VERSION.zip.sha256"
