#!/bin/bash
# Regenerates Resources/AppIcon.png and Resources/AppIcon.icns from Resources/AppIcon.svg.
# The outputs are checked in, so normal builds don't need librsvg.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || {
    echo "Icon regeneration requires rsvg-convert (Homebrew: librsvg)." >&2
    exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"

rsvg-convert --width 1024 --height 1024 Resources/AppIcon.svg --output "$WORK/AppIcon.png"
for size in 16 32 128 256 512; do
    retina=$((size * 2))
    # Render each size from the vector so small sizes stay crisp.
    rsvg-convert --width "$size" --height "$size" Resources/AppIcon.svg --output "$ICONSET/icon_${size}x${size}.png"
    rsvg-convert --width "$retina" --height "$retina" Resources/AppIcon.svg --output "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil --convert icns "$ICONSET" --output "$WORK/AppIcon.icns"
cp "$WORK/AppIcon.png" Resources/AppIcon.png
cp "$WORK/AppIcon.icns" Resources/AppIcon.icns
echo "Generated Resources/AppIcon.png and Resources/AppIcon.icns."
