#!/bin/zsh
# Builds MyNotch.app and packs it into build/MyNotch.dmg (drag-to-Applications layout).
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh
STAGE=build/dmg
rm -rf "$STAGE" build/MyNotch.dmg
mkdir -p "$STAGE"
cp -R build/MyNotch.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname MyNotch -srcfolder "$STAGE" -ov -format UDZO build/MyNotch.dmg >/dev/null
rm -rf "$STAGE"
echo "✓ build/MyNotch.dmg ($(du -h build/MyNotch.dmg | cut -f1))"
