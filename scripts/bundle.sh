#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP_OUTPUT:-$PWD/dist/Mergeport.app}"
swift scripts/require-stopped-app.swift "$APP"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION must be major.minor.patch" >&2; exit 1; }
CLIENT_ID="${GITHUB_OAUTH_CLIENT_ID:-$(/usr/libexec/PlistBuddy -c 'Print :MergeportGitHubClientID' Resources/Info.plist)}"
if [ -n "$CLIENT_ID" ] && [[ ! "$CLIENT_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "GITHUB_OAUTH_CLIENT_ID must be a public GitHub Client ID, without whitespace or other special characters." >&2
    exit 1
fi
LINEAR_CLIENT_ID="${LINEAR_OAUTH_CLIENT_ID:-$(/usr/libexec/PlistBuddy -c 'Print :MergeportLinearClientID' Resources/Info.plist 2>/dev/null || true)}"
if [ -n "$LINEAR_CLIENT_ID" ] && [[ ! "$LINEAR_CLIENT_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "LINEAR_OAUTH_CLIENT_ID must be a public Linear Client ID, without whitespace or other special characters." >&2
    exit 1
fi
if [ -z "$CLIENT_ID" ]; then
    echo "Warning: this build has no bundled GitHub integration. Set GITHUB_OAUTH_CLIENT_ID before distributing it." >&2
fi
# Xcode 27's Swift Build links with --sysroot, which records the deployment target as the SDK
# version and makes AppKit drop the macOS 26+ window design. Passing -isysroot restores the real SDK.
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
BUILD_ARGS=(-c release --disable-automatic-resolution
    -Xswiftc -Xclang-linker -Xswiftc -isysroot
    -Xswiftc -Xclang-linker -Xswiftc "$SDK_PATH")
if [ -n "${BUILD_ARCH:-}" ]; then BUILD_ARGS+=(--arch "$BUILD_ARCH"); fi
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
LINKED_SDK="$(xcrun vtool -show-build "$BIN/Mergeport" | awk '$1 == "sdk" { print $2; exit }')"
if [ "$LINKED_SDK" != "$SDK_VERSION" ]; then
    echo "Built binary SDK ($LINKED_SDK) does not match selected macOS SDK ($SDK_VERSION)" >&2
    exit 1
fi

mkdir -p "$PWD/dist"
STAGING="$(mktemp -d "$PWD/dist/.bundle.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
NEW="$STAGING/Mergeport.app"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources" "$NEW/Contents/Frameworks"
cp "$BIN/Mergeport" "$NEW/Contents/MacOS/Mergeport"
cp Resources/Info.plist "$NEW/Contents/Info.plist"
PLIST="$NEW/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :MergeportGitHubClientID $CLIENT_ID" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :MergeportLinearClientID" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :MergeportLinearClientID string $LINEAR_CLIENT_ID" "$PLIST"
plutil -lint "$PLIST"
cp Resources/AppIcon.icns "$NEW/Contents/Resources/AppIcon.icns"
ditto "$BIN/Sparkle.framework" "$NEW/Contents/Frameworks/Sparkle.framework"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$NEW/Contents/Resources/Sparkle-LICENSE.txt"

# Local builds prefer an Apple Development certificate: it keeps Keychain "Always Allow"
# valid across rebuilds, whereas ad-hoc signatures change every build. CI signs ad-hoc
# here and re-signs with the pinned Developer ID during release.
if [ -z "${CODESIGN_IDENTITY+x}" ] && [ -z "${CI:-}" ]; then
    CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: /{print $2; exit}')"
    [ -n "$CODESIGN_IDENTITY" ] || echo "Warning: no Apple Development certificate; Keychain will ask again after every rebuild." >&2
fi
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}" bash scripts/sign.sh "$NEW"

# The destination may have been launched while the build was running.
swift scripts/require-stopped-app.swift "$APP"
if [ -e "$APP" ]; then
    [ ! -L "$APP" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "dev.wouter.mergeport" ] \
        || { echo "Refusing to replace an unexpected bundle at $APP" >&2; exit 1; }
    mv "$APP" "$STAGING/previous.app"
fi
mkdir -p "$(dirname "$APP")"
if ! mv "$NEW" "$APP"; then
    if [ -d "$STAGING/previous.app" ]; then mv "$STAGING/previous.app" "$APP"; fi
    echo "Failed to replace app bundle" >&2
    exit 1
fi
echo "Built: $APP ($VERSION)"
