#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build -c release
bin="$(swift build -c release --show-bin-path)"
app="$(pwd)/build/Hush.app"
if [ -d "$app" ]; then
    rm -rf "$app"
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/Hush" "$app/Contents/MacOS/Hush"
cp Info.plist "$app/Contents/Info.plist"
cp Sources/Hush/Resources/HushIcon.icns "$app/Contents/Resources/HushIcon.icns"
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
