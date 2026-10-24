#!/usr/bin/env bash
# Builds a self-contained build/Glide.app for Apple Silicon.
# Requires: Xcode (or Command Line Tools), `brew install mpv pkgconf`.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Glide.app"

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Glide" "$APP/Contents/MacOS/Glide"
cp Packaging/Info.plist "$APP/Contents/Info.plist"

# App icon
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Packaging/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Packaging/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# libmpv + FFmpeg & co. from Homebrew into Contents/Frameworks
python3 Packaging/bundle_dylibs.py "$APP"

# install_name_tool invalidated signatures; Apple Silicon refuses unsigned code.
codesign --force --sign - "$APP"/Contents/Frameworks/*
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "Готово: $APP"
