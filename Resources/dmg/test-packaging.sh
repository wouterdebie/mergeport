#!/bin/bash
# Integration/regression tests; only private copies of the input are modified.
set -euo pipefail
[[ $# == 1 ]] || { echo "Usage: $0 APP_PATH" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
WORK="$ROOT/dist/.dmg-tests-$(uuidgen)"
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
expect_failure() {
    if "$@" >"$WORK/failure.log" 2>&1; then
        echo "Unexpected success: $*" >&2
        exit 1
    fi
    tail -3 "$WORK/failure.log"
}
bash "$ROOT/scripts/make-dmg.sh" "$APP" "$WORK/valid.dmg"
BEFORE="$(shasum -a 256 "$WORK/valid.dmg")"
expect_failure bash "$ROOT/scripts/make-dmg.sh" "$APP" "$WORK/valid.dmg"
[[ "$BEFORE" == "$(shasum -a 256 "$WORK/valid.dmg")" ]]
ln -s "$WORK/valid.dmg" "$WORK/symlink.dmg"
expect_failure bash "$ROOT/scripts/make-dmg.sh" "$APP" "$WORK/symlink.dmg"
[[ "$BEFORE" == "$(shasum -a 256 "$WORK/valid.dmg")" ]]
expect_failure bash "$ROOT/scripts/make-dmg.sh" "$WORK/absent.app" "$WORK/absent.dmg"
[[ ! -e "$WORK/absent.dmg" ]]
expect_failure bash "$ROOT/scripts/make-dmg.sh" "$APP" "$APP/.dmg-test-output/invalid.dmg"
[[ ! -e "$APP/.dmg-test-output" ]]
mkdir "$MOUNT"
hdiutil convert -quiet "$WORK/valid.dmg" -format UDRW -o "$WORK/fixture.dmg"
attach() {
    hdiutil attach -nobrowse -noautoopen -mountpoint "$MOUNT" "$WORK/fixture.dmg"
}
check_fixture_fails() {
    local name="$1" expected="$2"
    hdiutil detach "$MOUNT"
    hdiutil convert -quiet "$WORK/fixture.dmg" -format UDZO -o "$WORK/$name.dmg"
    expect_failure bash "$ROOT/scripts/check-dmg.sh" "$WORK/$name.dmg"
    grep -F "$expected" "$WORK/failure.log" >/dev/null
    echo "PASS: $name rejected"
}
attach
rm "$MOUNT/Applications"
ln -s /System/Applications "$MOUNT/Applications"
check_fixture_fails wrong-link "Applications must be a symlink to /Applications"
attach
rm "$MOUNT/Applications"
ln -s /Applications "$MOUNT/Applications"
mv "$MOUNT/.DS_Store" "$WORK/saved.DS_Store"
check_fixture_fails missing-layout "Finder metadata is missing"
attach
cp "$WORK/saved.DS_Store" "$MOUNT/.DS_Store"
printf '\n' >> "$MOUNT/Mergeport.app/Contents/Info.plist"
check_fixture_fails modified-app "invalid"
codesign --verify --deep --strict "$APP"
echo "PASS: valid image, overwrite/symlink/input guards, link/layout/signature rejection, original app signature."
