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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Lookout" "$BIN/lookout-hook" "$APP/Contents/MacOS/"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Lookout"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/ClaudeLogo.pdf Resources/CodexLogo.pdf "$APP/Contents/Resources/"
./scripts/package-vscode.sh
cp build/lookout-vscode.vsix "$APP/Contents/Resources/"
cp Remote/lookout-hook "$APP/Contents/Resources/remote-lookout-hook"

codesign --force --sign - --identifier io.github.aslkhon.lookout.hook "$APP/Contents/MacOS/lookout-hook"
# Sparkle's helpers (Autoupdate, Updater.app, XPC services) first, then the framework.
codesign --force --deep --sign - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
ZIP="build/Lookout-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $APP and $ZIP"
shasum -a 256 "$ZIP"
