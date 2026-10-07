#!/bin/bash
set +x
set -euo pipefail
cd "$(dirname "$0")/.."

[ "$#" -le 1 ] || { echo "Usage: bash scripts/notarize.sh [disk-image.dmg]" >&2; exit 1; }
if [ "$#" -eq 1 ]; then
    [[ "$1" == *.dmg ]] && [ -f "$1" ] || { echo "Expected an existing .dmg file" >&2; exit 1; }
    TARGET="$1"
    ARCHIVE="$TARGET"
    codesign --verify --strict "$TARGET"
else
    TARGET="$PWD/dist/Mergeport.app"
    ARCHIVE="$PWD/dist/Mergeport-notarize.zip"
    codesign --verify --deep --strict "$TARGET"
    ditto -c -k --keepParent "$TARGET" "$ARCHIVE"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
else
    : "${APPLE_ID:?Set NOTARY_PROFILE or APPLE_ID}"
    : "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
    : "${APPLE_APP_SPECIFIC_PASSWORD:?Set APPLE_APP_SPECIFIC_PASSWORD}"
    AUTH=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD")
fi
SUBMISSION="$(xcrun notarytool submit "$ARCHIVE" "${AUTH[@]}" --output-format json)"
ID="$(printf '%s' "$SUBMISSION" | jq -er '.id')"
echo "Notarization submission: $ID"
DEADLINE=$((SECONDS + 3300))
STATUS="In Progress"
while [ "$SECONDS" -lt "$DEADLINE" ]; do
    sleep 20
    if ! INFO="$(xcrun notarytool info "$ID" "${AUTH[@]}" --output-format json)"; then
        echo "Notarization status request failed; retrying." >&2
        continue
    fi
    STATUS="$(printf '%s' "$INFO" | jq -er '.status')"
    echo "Notarization status: $STATUS"
    [ "$STATUS" = "In Progress" ] || break
done
if [ "$STATUS" != "Accepted" ]; then
    xcrun notarytool log "$ID" "${AUTH[@]}" || echo "Could not retrieve notarization log." >&2
    echo "Notarization failed or timed out: $STATUS" >&2
    exit 1
fi
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
if [ "$#" -eq 1 ]; then
    spctl --assess --type open --context context:primary-signature --verbose=2 "$TARGET"
else
    spctl --assess --type execute --verbose=2 "$TARGET"
fi
