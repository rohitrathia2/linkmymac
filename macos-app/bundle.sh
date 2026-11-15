#!/bin/sh
# Builds ../LinkMyMac.app from source: release binary + Info.plist + icon/logo, ad-hoc signed.
# The .app is build output (git-ignored); this script is the only way it should be produced.
set -eu
cd "$(dirname "$0")"

swift build -c release

APP=../LinkMyMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LinkMyMac "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Sources/LinkMyMac/Resources/AppIcon.icns Sources/LinkMyMac/Resources/logo.png "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

echo "Built $(cd "$APP" && pwd)"
