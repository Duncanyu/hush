#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build -c release
bin="$(swift build -c release --show-bin-path)"
app="$(pwd)/build/Hush.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/Hush" "$app/Contents/MacOS/Hush"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
dist="$(pwd)/dist/Hush.app"
if [ -L "$dist" ]; then
    unlink "$dist"
elif [ -d "$dist" ]; then
    rm -rf "$dist"
fi
mkdir -p "$(dirname "$dist")"
cp -R "$app" "$dist"
echo "$app"
echo "$dist"
