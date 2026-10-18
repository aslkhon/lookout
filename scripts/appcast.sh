#!/bin/sh
# Writes build/appcast.xml for build/Lookout-<version>.zip, signed with the EdDSA key in the
# login Keychain (account io.github.aslkhon.lookout). Upload both to the GitHub release:
#   gh release create v<version> build/Lookout-<version>.zip build/appcast.xml
# Usage: scripts/appcast.sh [download URL base]   (default: the GitHub release for this version)
set -eu
cd "$(dirname "$0")/.."

PLIST=Resources/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST")
MIN_OS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$PLIST")
ZIP="build/Lookout-$VERSION.zip"
BASE=${1:-https://github.com/aslkhon/lookout/releases/download/v$VERSION}

[ -f "$ZIP" ] || { echo "No $ZIP; run scripts/build-app.sh first" >&2; exit 1; }
SIGN_UPDATE=.build/artifacts/sparkle/Sparkle/bin/sign_update
[ -x "$SIGN_UPDATE" ] || swift package resolve
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE=$("$SIGN_UPDATE" --account io.github.aslkhon.lookout "$ZIP")

cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Lookout</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/aslkhon/lookout/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="$BASE/Lookout-$VERSION.zip" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
echo "Wrote build/appcast.xml for $VERSION ($BUILD)"
