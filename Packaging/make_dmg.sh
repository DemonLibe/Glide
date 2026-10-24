#!/usr/bin/env bash
# Packs build/Glide.app into build/Glide.dmg (with an Applications shortcut).
set -euo pipefail
cd "$(dirname "$0")/.."

STAGE="build/dmg"
rm -rf "$STAGE" build/Glide.dmg
mkdir -p "$STAGE"
ditto build/Glide.app "$STAGE/Glide.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Glide -srcfolder "$STAGE" -ov -format UDZO build/Glide.dmg
echo "Готово: build/Glide.dmg"
