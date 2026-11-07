#!/bin/bash
# Compile assets/AppIcon.icon (Icon Composer: layered Liquid Glass icon) into what the app bundle uses:
#   compiled/Assets.car   layered icon for macOS 26+
#   compiled/AppIcon.icns flat fallback for macOS 14-15
#   icon.png              preview for the README
# Needs full Xcode (actool, Icon Composer). The outputs are committed, so build.sh doesn't need Xcode.
# Edit the icon: open assets/AppIcon.icon in Icon Composer (Xcode → Open Developer Tool), then run this.
set -euo pipefail
cd "$(dirname "$0")"
HERE="$(pwd)"  # absolute paths: actool runs through a daemon with its own working directory
ICTOOL="$(dirname "$(xcode-select -p)")/Applications/Icon Composer.app/Contents/Executables/ictool"
rm -rf compiled && mkdir compiled
xcrun actool "$HERE/AppIcon.icon" --compile "$HERE/compiled" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$(mktemp -d)/partial.plist" >/dev/null
"$ICTOOL" AppIcon.icon --export-image --output-file icon.png --platform macOS --rendition Default \
    --width 512 --height 512 --scale 1 >/dev/null
ls compiled icon.png
