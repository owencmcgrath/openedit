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
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Rebuild one .icns from a 1024x1024 source PNG, emitting every representation
# iconutil expects.
build_icns() {
    local src="$1" out="$2"
    local iconset="$TMP/$(basename "$out" .icns).iconset"
    mkdir -p "$iconset"

    local size
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$src" --out "$iconset/icon_${size}x${size}.png" >/dev/null
        local doubled=$((size * 2))
        sips -z "$doubled" "$doubled" "$src" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done

    iconutil -c icns "$iconset" -o "$out"
}

build_icns "icons/light-mode-default.png" "Resources/AppIcon-Light.icns"
build_icns "icons/dark-mode-default.png" "Resources/AppIcon-Dark.icns"
cp "Resources/AppIcon-Light.icns" "Resources/AppIcon.icns"

echo "Wrote Resources/AppIcon.icns, AppIcon-Light.icns, AppIcon-Dark.icns"
