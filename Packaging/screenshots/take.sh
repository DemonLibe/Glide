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
    echo "=== launch: $*" >> "$OUT/log.txt"
    build/Glide.app/Contents/MacOS/Glide "$@" >> "$OUT/log.txt" 2>&1 &
    sleep 8
    build/window_id --dump >> "$OUT/log.txt"
}

window() {
    local id; id="$(build/window_id)"
    if [[ -n "$id" ]]; then screencapture -x -o -l "$id" "$OUT/$1.png"; else screencapture -x "$OUT/$1.png"; fi
}

# Opens a pop-up menu in the controls bar by its tooltip, e.g. "субтитры".
click_control() {
    osascript <<APPLESCRIPT
tell application "System Events" to tell process "Glide"
    repeat with element in (entire contents of window 1)
        try
            if role of element is "AXMenuButton" and help of element contains "$1" then
                click element
                return
            end if
        end try
    end repeat
end tell
APPLESCRIPT
}

close_menu() { osascript -e 'tell application "System Events" to key code 53'; sleep 1; }

launch
window 1-start

launch -GlideKeepControlsVisible YES "$SAMPLE"
window 2-player
click_control "субтитры" && sleep 1 && screencapture -x "$OUT/5-menu-tracks.png"
close_menu
click_control "Скорость" && sleep 1 && screencapture -x "$OUT/6-menu-speed.png"
close_menu

launch -GlideKeepControlsVisible YES -GlideShowStats YES "$SAMPLE"
window 3-stats
osascript -e 'tell application "System Events" to tell process "Glide" to click menu bar item "Воспроизведение" of menu bar 1' \
    && sleep 1 && screencapture -x "$OUT/4-menu-playback.png"
close_menu

pkill -x Glide
ls -la "$OUT"
