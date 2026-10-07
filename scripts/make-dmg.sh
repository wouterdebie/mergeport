#!/bin/bash
# Build a styled, read-only installer without Finder automation.
set -euo pipefail
[[ $# == 2 ]] || { echo "Usage: $0 APP_PATH OUTPUT_DMG" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASSETS="$ROOT/Resources/dmg"
[[ -d "$1/Contents" ]] || { echo "App bundle not found: $1" >&2; exit 1; }
[[ "$(basename "$1")" == "Mergeport.app" ]] || { echo "Expected a Mergeport.app bundle." >&2; exit 1; }
APP="$(cd "$1" && pwd -P)"
[[ "$2" == *.dmg ]] || { echo "Output must end in .dmg" >&2; exit 1; }
# Resolve/create one parent at a time, rejecting even symlink/../ paths into the
# source bundle before any directory can be created there.
output_directory() {
    local path="$1" parent resolved
    if [[ -d "$path" ]]; then
        resolved="$(cd "$path" && pwd -P)"
    else
        parent="$(output_directory "$(dirname "$path")")" || return 1
        resolved="$parent/$(basename "$path")"
    fi
    case "$resolved" in
        "$APP"|"$APP"/*) echo "Output must not be inside the source app." >&2; return 1 ;;
    esac
    mkdir -p "$resolved"
    (cd "$resolved" && pwd -P)
}
OUT="$(output_directory "$(dirname "$2")")/$(basename "$2")"
[[ ! -e "$OUT" && ! -L "$OUT" ]] || { echo "Refusing to overwrite: $OUT" >&2; exit 1; }
[[ -f "$ASSETS/layout.dmg" && -s "$ASSETS/Finder.DS_Store" && -s "$ASSETS/background.tiff" ]] ||
    { echo "Styled Finder template is missing; no unstyled fallback is permitted." >&2; exit 1; }
codesign --verify --deep --strict "$APP"
WORK="$(dirname "$OUT")/.make-dmg-$(uuidgen)"
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
hdiutil verify -quiet "$ASSETS/layout.dmg"
hdiutil convert -quiet "$ASSETS/layout.dmg" -format UDRW -o "$WORK/writable.dmg"
# Preserve the template filesystem's identity/catalog IDs so its background
# alias resolves on every machine, not just the authoring machine.
APP_KB="$(du -sk "$APP" | awk '{print $1}')"
SIZE_MB=$((APP_KB / 1024 + 96))
hdiutil resize -quiet -size "${SIZE_MB}m" "$WORK/writable.dmg"
hdiutil attach -nobrowse -noautoopen -owners off -mountpoint "$MOUNT" "$WORK/writable.dmg"
[[ ! -e "$MOUNT/Mergeport.app" ]] || { echo "Template unexpectedly contains an app." >&2; exit 1; }
ditto "$APP" "$MOUNT/Mergeport.app"
codesign --verify --deep --strict "$MOUNT/Mergeport.app"
hdiutil detach "$MOUNT"
hdiutil convert -quiet "$WORK/writable.dmg" -format UDZO -imagekey zlib-level=9 -o "$WORK/result.dmg"
bash "$ROOT/scripts/check-dmg.sh" "$WORK/result.dmg"
# A hard link publishes atomically and fails if another process created OUT.
ln -h "$WORK/result.dmg" "$OUT"
echo "Created styled installer: $OUT"
