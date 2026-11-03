#!/bin/sh
# Builds TapScreen.app and installs it to the Desktop (override with TAPSCREEN_DEST=/path/TapScreen.app).
#   scripts/build.sh               release build, install, launch
#   scripts/build.sh --no-install  just build into build/TapScreen.app
set -e
MODE="$1"
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BUILD="$ROOT/build"
APP="$BUILD/TapScreen.app"
mkdir -p "$BUILD"

echo "Compiling…"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos14.0 \
  -framework IOKit -framework AVFoundation -framework ServiceManagement -framework Carbon \
  $(find Sources -name '*.swift') -o "$BUILD/TapScreen"

echo "Bundling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/TapScreen" "$APP/Contents/MacOS/TapScreen"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ ! -f "$BUILD/AppIcon.icns" ]; then
  swiftc -O scripts/make_icon.swift -o "$BUILD/make_icon"
  rm -rf "$BUILD/AppIcon.iconset"
  "$BUILD/make_icon" "$BUILD/AppIcon.iconset"
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# A stable certificate keeps macOS permissions (Accessibility, Input Monitoring) across rebuilds; ad hoc signing
# looks like a brand-new app every time. Create one once in Keychain Access → Certificate Assistant →
# Create a Certificate…, name "TapScreen Developer", type "Code Signing".
IDENTITY="-"
if security find-identity -p codesigning 2>/dev/null | grep -q '"TapScreen Developer"'; then IDENTITY="TapScreen Developer"; fi
codesign --force --sign "$IDENTITY" --identifier app.tapscreen.TapScreen "$APP"
[ "$IDENTITY" = "-" ] && echo "Signed ad hoc: macOS will ask for permissions again after this build (see scripts/build.sh)."

if [ "$MODE" != "--no-install" ]; then
  DEST="${TAPSCREEN_DEST:-$HOME/Desktop/TapScreen.app}"
  pkill -x TapScreen 2>/dev/null && sleep 0.5 || true
  rm -rf "$DEST"
  # Move, not copy: one TapScreen.app on the Mac, so macOS never mixes up which one has permission.
  mv "$APP" "$DEST"
  echo "Installed to $DEST"
  open "$DEST"
fi
echo "Done."
