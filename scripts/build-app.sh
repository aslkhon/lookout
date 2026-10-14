#!/bin/sh
# Builds build/Lookout.app (release, universal, ad-hoc signed) and build/Lookout-<version>.zip.
set -eu
cd "$(dirname "$0")/.."

ARCHS="--arch arm64 --arch x86_64"
swift build -c release $ARCHS --product Lookout
swift build -c release $ARCHS --product lookout-hook
BIN=$(swift build -c release $ARCHS --show-bin-path)

APP=build/Lookout.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Lookout" "$BIN/lookout-hook" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

codesign --force --sign - --identifier io.github.aslkhon.lookout.hook "$APP/Contents/MacOS/lookout-hook"
codesign --force --sign - "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ZIP="build/Lookout-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $APP and $ZIP"
shasum -a 256 "$ZIP"
