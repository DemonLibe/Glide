#!/usr/bin/env bash
# Launches build/Glide.app in a few states and captures screenshots into build/screenshots.
set -uo pipefail
cd "$(dirname "$0")/../.."

OUT="build/screenshots"
SAMPLE="$PWD/build/demo/Демо 4K 120fps.mkv"
mkdir -p "$OUT"
swiftc -O Packaging/screenshots/window_id.swift -o build/window_id

launch() {
    pkill -x Glide; sleep 1
    open -n build/Glide.app --args "$@"
    sleep 8
}

window() {
    local id; id="$(build/window_id)"
    if [[ -n "$id" ]]; then screencapture -x -o -l "$id" "$OUT/$1.png"; else screencapture -x "$OUT/$1.png"; fi
}

launch
window 1-start

launch -GlideKeepControlsVisible YES "$SAMPLE"
window 2-player

launch -GlideKeepControlsVisible YES -GlideShowStats YES "$SAMPLE"
window 3-stats

# Menus need UI scripting; skipped silently if the runner doesn't allow it.
osascript -e 'tell application "System Events" to tell process "Glide" to click menu bar item "Воспроизведение" of menu bar 1' \
    && sleep 1 && screencapture -x "$OUT/4-menu-playback.png"
osascript -e 'tell application "System Events" to key code 53' 2>/dev/null
osascript -e 'tell application "System Events" to tell process "Glide" to click menu bar item "Файл" of menu bar 1' \
    && sleep 1 && screencapture -x "$OUT/5-menu-file.png"

pkill -x Glide
ls -la "$OUT"
