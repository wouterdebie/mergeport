#!/bin/bash
# Interactive authoring only. Release builds never run Finder or AppleScript.
set -euo pipefail
[[ $# == 1 ]] || { echo "Usage: $0 APP_PATH" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ASSETS="$ROOT/Resources/dmg"
[[ ! -e "$ASSETS/layout.dmg" ]] || { echo "layout.dmg already exists; move it aside first." >&2; exit 1; }
[[ -d "$1/Contents" ]] || { echo "App bundle not found: $1" >&2; exit 1; }
WORK="$ASSETS/.author-$(uuidgen)"
mkdir -m 700 "$WORK"
MOUNT="$WORK/mount"
cleanup() {
    local status=$?
    trap - EXIT
    if mount | grep -F " on $MOUNT (" >/dev/null; then
        hdiutil detach "$MOUNT" || { echo "Could not detach $MOUNT; keeping $WORK" >&2; exit 1; }
    fi
    rm -rf "$WORK"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$WORK/stage" "$MOUNT"
ditto "$1" "$WORK/stage/Mergeport.app"
ln -s /Applications "$WORK/stage/Applications"
mkdir "$WORK/stage/.background"
cp "$ASSETS/background.tiff" "$WORK/stage/.background/"
hdiutil create -quiet -size 64m -fs HFS+ -volname "Mergeport" \
    -srcfolder "$WORK/stage" -format UDRW "$WORK/template.dmg"
hdiutil attach -nobrowse -noautoopen -mountpoint "$MOUNT" "$WORK/template.dmg"
osascript "$ASSETS/layout.applescript" "$MOUNT"
[[ -s "$MOUNT/.DS_Store" ]] || { echo "Finder did not write .DS_Store" >&2; exit 1; }
cp "$MOUNT/.DS_Store" "$ASSETS/Finder.DS_Store"
# Only the placeholder in our private image is removed, never the input app.
rm -rf "$MOUNT/Mergeport.app"
cp "$ASSETS/Finder.DS_Store" "$MOUNT/.DS_Store"
hdiutil detach "$MOUNT"
hdiutil convert -quiet "$WORK/template.dmg" -format UDZO -o "$ASSETS/layout.dmg"
hdiutil verify -quiet "$ASSETS/layout.dmg"
