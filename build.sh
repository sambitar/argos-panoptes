#!/bin/bash
# Builds CopyText.app into dist/.
#   ./build.sh              native (arm64 on Apple Silicon)
#   UNIVERSAL=1 ./build.sh  arm64 + x86_64 fat binary
# Ad-hoc signed with a stable identifier so macOS remembers the Screen
# Recording permission across launches.
set -euo pipefail
cd "$(dirname "$0")"

if [ "${UNIVERSAL:-0}" = "1" ]; then
    swift build -c release --arch arm64 --arch x86_64
    binary=".build/out/Products/Release/CopyText"
else
    swift build -c release
    binary=".build/release/CopyText"
fi

APP="dist/CopyText.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$binary" "$APP/Contents/MacOS/CopyText"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# TCC keys off the identifier, so sign with a stable one.
codesign --force --sign - --identifier com.local.copytext "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/CopyText")) — run: open $APP"
