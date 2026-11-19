#!/bin/bash
# Universal (arm64 + x86_64) Kalıntısız.app üretir: build/Kalıntısız.app
set -euo pipefail

cd "$(dirname "$0")/.."

APP="build/Kalıntısız.app"
BIN_NAME="Kalintisiz"

echo "==> arm64 derleniyor"
swift build -c release --triple arm64-apple-macosx15.0
echo "==> x86_64 derleniyor"
swift build -c release --triple x86_64-apple-macosx15.0

ARM_BIN="$(swift build -c release --triple arm64-apple-macosx15.0 --show-bin-path)/$BIN_NAME"
X86_BIN="$(swift build -c release --triple x86_64-apple-macosx15.0 --show-bin-path)/$BIN_NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> lipo"
lipo -create "$ARM_BIN" "$X86_BIN" -output "$APP/Contents/MacOS/$BIN_NAME"
cp App/Info.plist "$APP/Contents/Info.plist"

xattr -cr "$APP"
echo "==> imzalanıyor (ad-hoc)"
codesign --force --deep -s - --entitlements App/Kalintisiz.entitlements "$APP"

lipo -info "$APP/Contents/MacOS/$BIN_NAME"
codesign -v "$APP"
echo "==> Hazır: $APP"
