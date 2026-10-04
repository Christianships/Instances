#!/bin/zsh
# Builds Instances.app and installs it to ~/Applications.
#   ./build.sh          build + install + open the panel
#   ./build.sh --no-run build + install only
set -euo pipefail
cd "${0:A:h}"

APP=build/Instances.app
DEST="$HOME/Applications/Instances.app"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -o "$APP/Contents/MacOS/Instances" Sources/*.swift

cp Info.plist "$APP/Contents/"
cp Icon/AppIcon.icns "$APP/Contents/Resources/"   # redraw: swift Icon/make-icon.swift
codesign --force --sign - --identifier dev.christianaguilar.instances "$APP"

pkill -x Instances 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST" && cp -R "$APP" "$DEST"
echo "Installed $DEST"

[[ "${1:-}" == "--no-run" ]] || open "$DEST"
