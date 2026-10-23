#!/usr/bin/env bash
# Packs build/MacPlayer.app into build/MacPlayer.dmg (with an Applications shortcut).
set -euo pipefail
cd "$(dirname "$0")/.."

STAGE="build/dmg"
rm -rf "$STAGE" build/MacPlayer.dmg
mkdir -p "$STAGE"
ditto build/MacPlayer.app "$STAGE/MacPlayer.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname MacPlayer -srcfolder "$STAGE" -ov -format UDZO build/MacPlayer.dmg
echo "Готово: build/MacPlayer.dmg"
