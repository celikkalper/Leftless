#!/bin/bash
# Builds a universal (arm64 + x86_64) Leftless.app with compiled string catalogs: build/Leftless.app
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Leftless.app"
BIN_NAME="Leftless"
DD="build/DerivedData"
LANGS=(tr de fr es ja pt-BR)

fail() { echo "ERROR: $*" >&2; exit 1; }

if [ ! -d Leftless.xcodeproj ] || [ project.yml -nt Leftless.xcodeproj/project.pbxproj ]; then
  echo "==> xcodegen generate"
  xcodegen generate
fi

echo "==> xcodebuild (Release, arm64 + x86_64)"
xcodebuild -project Leftless.xcodeproj -scheme Leftless -configuration Release \
  -derivedDataPath "$DD" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO build

PRODUCT="$DD/Build/Products/Release/Leftless.app"
[ -d "$PRODUCT" ] || fail "build product not found: $PRODUCT"

rm -rf "$APP"
mkdir -p build
ditto "$PRODUCT" "$APP"

# Xcode signing is skipped (xattrs on synced folders break it); we sign below.
xattr -cr "$APP"
echo "==> codesign (ad-hoc)"
codesign --force --deep -s - --entitlements App/Leftless.entitlements "$APP"

echo "==> checks"
LIPO="$(lipo -info "$APP/Contents/MacOS/$BIN_NAME")"
echo "$LIPO"
case "$LIPO" in *x86_64*) ;; *) fail "x86_64 slice missing";; esac
case "$LIPO" in *arm64*) ;; *) fail "arm64 slice missing";; esac
codesign -v "$APP"

CORE="$(find "$APP/Contents" -maxdepth 3 -type d -name 'Leftless_LeftlessCore.bundle' | head -1)"
[ -n "$CORE" ] || fail "Leftless_LeftlessCore.bundle missing from app"
echo "core bundle: $CORE"

has_lproj() { [ -d "$1/$2.lproj" ] || [ -d "$1/${2//-/_}.lproj" ]; }
for dir in "$APP/Contents/Resources" "$CORE" "$CORE/Contents/Resources"; do
  [ -d "$dir" ] || continue
  ok=1
  for l in "${LANGS[@]}"; do has_lproj "$dir" "$l" || ok=0; done
  [ "$dir" = "$CORE" ] && [ $ok = 0 ] && continue
  [ "$dir" = "$CORE/Contents/Resources" ] && [ $ok = 0 ] && continue
  [ $ok = 1 ] || fail "missing .lproj folders in $dir"
done
for dir in "$CORE" "$CORE/Contents/Resources"; do
  [ -d "$dir" ] || continue
  ok=1; for l in "${LANGS[@]}"; do has_lproj "$dir" "$l" || ok=0; done
  [ $ok = 1 ] && found_core=1
done
[ "${found_core:-0}" = 1 ] || fail "core bundle lacks .lproj folders"

echo "==> Ready: $APP"
