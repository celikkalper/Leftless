#!/usr/bin/env bash
# Builds the universal app and packs it into a drag-to-install disk image:
#   build/Leftless-<version>.dmg  (Leftless.app + a shortcut to /Applications)
# Usage: ./scripts/make-dmg.sh [--skip-build]
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "ERROR: $*" >&2; exit 1; }

if [ "${1:-}" != "--skip-build" ]; then
  ./scripts/build-universal.sh
fi

APP="build/Leftless.app"
[ -d "$APP" ] || fail "$APP not found; run ./scripts/build-universal.sh first"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[ -n "$VERSION" ] || fail "could not read the app version"

STAGE="build/dmg-stage"
DMG="build/Leftless-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Leftless.app"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create $DMG"
hdiutil create -volname "Leftless $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
hdiutil verify "$DMG" >/dev/null || fail "disk image failed verification"

shasum -a 256 "$DMG"
echo "==> Ready: $DMG"
