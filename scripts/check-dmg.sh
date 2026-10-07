#!/bin/bash
# Check the installer without opening Finder or modifying/running the app.
set -euo pipefail
[[ $# == 1 ]] || { echo "Usage: $0 DMG_PATH" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/Resources/dmg"
DMG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
[[ -f "$DMG" ]] || { echo "Disk image not found: $1" >&2; exit 1; }
WORK="$ROOT/dist/.check-dmg-$(uuidgen)"
mkdir -p "$ROOT/dist"
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
mkdir "$MOUNT"
hdiutil verify "$DMG"
hdiutil imageinfo -plist "$DMG" > "$WORK/image.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :Format' "$WORK/image.plist")" == UDZO ]] ||
    { echo "Expected a read-only compressed UDZO image." >&2; exit 1; }
# A private copy avoids reusing or detaching an image the user already opened.
ditto "$DMG" "$WORK/installer.dmg"
hdiutil attach -readonly -nobrowse -noautoopen -owners off -mountpoint "$MOUNT" "$WORK/installer.dmg"
[[ -d "$MOUNT/Mergeport.app/Contents" && ! -L "$MOUNT/Mergeport.app" ]] ||
    { echo "Mergeport.app is missing or is a symlink." >&2; exit 1; }
[[ -L "$MOUNT/Applications" && "$(readlink "$MOUNT/Applications")" == /Applications ]] ||
    { echo "Applications must be a symlink to /Applications." >&2; exit 1; }
[[ -f "$MOUNT/.DS_Store" && ! -L "$MOUNT/.DS_Store" ]] ||
    { echo "Finder metadata is missing." >&2; exit 1; }
[[ -f "$MOUNT/.background/background.tiff" && ! -L "$MOUNT/.background" && ! -L "$MOUNT/.background/background.tiff" ]] ||
    { echo "Installer background is missing." >&2; exit 1; }
cmp "$ASSETS/Finder.DS_Store" "$MOUNT/.DS_Store"
cmp "$ASSETS/background.tiff" "$MOUNT/.background/background.tiff"
shopt -s dotglob nullglob
for entry in "$MOUNT"/*; do
    case "$(basename "$entry")" in
        "Mergeport.app"|Applications|.DS_Store|.background) ;;
        .fseventsd|.Trashes|.Spotlight-V100|.HFS+*|.TemporaryItems) ;;
        *) echo "Unexpected installer item: $(basename "$entry")" >&2; exit 1 ;;
    esac
done
for entry in "$MOUNT/.background"/*; do
    [[ "$(basename "$entry")" == background.tiff ]] ||
        { echo "Unexpected background asset: $(basename "$entry")" >&2; exit 1; }
done
swift -module-cache-path "$WORK/swift-cache" "$ASSETS/verify-layout.swift" "$MOUNT"
codesign --verify --deep --strict "$MOUNT/Mergeport.app"
hdiutil detach "$MOUNT"
echo "Verified installer: $DMG"
