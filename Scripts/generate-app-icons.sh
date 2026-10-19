#!/usr/bin/env bash
# Regenerates the bundled .icns files from the source PNGs in icons/.
#
# The app is packaged with the Command Line Tools toolchain (build-app.sh),
# which cannot compile an appearance-aware Assets.car (actool needs full Xcode),
# so AppIconController instead swaps NSApp.applicationIconImage at runtime
# between the light and dark .icns this script produces. AppIcon.icns is the
# light artwork, named by CFBundleIconFile as the on-disk/Finder default.
#
# Sources: icons/light-mode-default.png and icons/dark-mode-default.png, the
# 1024x1024 composed exports from the Icon Composer documents in icons/*.icon.
#
# The composed exports are full-bleed (artwork to the canvas edge). macOS app
# icons leave a transparent safe-area margin so the squircle sits at the same
# visual size as other icons; without it the icon fills the whole Dock tile and
# looks oversized. The artwork is scaled to the standard 824x824 content box and
# centered on a transparent 1024x1024 canvas before the representations are cut.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ImageMagick does the transparent padding; sips alone cannot (its --padColor
# has no alpha channel).
if ! command -v magick >/dev/null 2>&1; then
    echo "error: ImageMagick (magick) is required to pad the icon artwork" >&2
    exit 1
fi

# Apple's macOS icon grid: artwork occupies 824 of the 1024 canvas, leaving a
# 100px transparent margin on every side.
CANVAS=1024
CONTENT=824

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Scale the full-bleed source into the safe-area content box on a transparent
# canvas, then cut every representation iconutil expects.
build_icns() {
    local src="$1" out="$2"
    local master="$TMP/$(basename "$out" .icns)-master.png"
    local iconset="$TMP/$(basename "$out" .icns).iconset"
    mkdir -p "$iconset"

    magick "$src" -resize "${CONTENT}x${CONTENT}" \
        -background none -gravity center -extent "${CANVAS}x${CANVAS}" "$master"

    local size
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
        local doubled=$((size * 2))
        sips -z "$doubled" "$doubled" "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done

    iconutil -c icns "$iconset" -o "$out"
}

build_icns "icons/light-mode-default.png" "Resources/AppIcon-Light.icns"
build_icns "icons/dark-mode-default.png" "Resources/AppIcon-Dark.icns"
cp "Resources/AppIcon-Light.icns" "Resources/AppIcon.icns"

echo "Wrote Resources/AppIcon.icns, AppIcon-Light.icns, AppIcon-Dark.icns"
