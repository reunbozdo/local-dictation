#!/bin/bash
# Regenerate assets/AppIcon.icns (and icon-1024.png for the README) from make_icon.swift.
set -euo pipefail
cd "$(dirname "$0")"
swift make_icon.swift icon-1024.png
SET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s icon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) icon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
echo "wrote AppIcon.icns"
