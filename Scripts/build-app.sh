#!/bin/bash
# Builds dist/Veltoret.app: release binary, VLCKit embedded, fonts and icon, ad-hoc signed (or with
# $VELTORET_SIGN_IDENTITY, e.g. "Developer ID Application: …", for distribution).
#   Scripts/build-app.sh [--debug]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=release; [ "${1:-}" = "--debug" ] && CONFIG=debug
VERSION="${VELTORET_VERSION:-1.0.0}"
BUILD="${VELTORET_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
# Build outside Documents/: iCloud adds Finder info to build products, which breaks code signing.
SCRATCH="${VELTORET_SCRATCH:-$HOME/Library/Caches/VeltoretBuild/app}"

Scripts/fetch-vlckit.sh
swift build -c "$CONFIG" --scratch-path "$SCRATCH" --product Veltoret
BIN_DIR="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)"

# Assemble outside Documents too, then copy the finished app into dist/.
STAGE="$SCRATCH/stage"
APP="$STAGE/Veltoret.app"
rm -rf "$STAGE"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN_DIR/Veltoret" "$APP/Contents/MacOS/Veltoret"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# SwiftPM resource bundles (fonts, images) go to Contents/Resources; Bundle.module finds them there.
for b in "$BIN_DIR"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
ditto Vendor/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework "$APP/Contents/Frameworks/VLCKit.framework"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
cp third_party/fonts/OFL.txt "$APP/Contents/Resources/OFL.txt"
cp Vendor/VLCKit-COPYING.txt "$APP/Contents/Resources/VLCKit-COPYING.txt" 2>/dev/null || true

xattr -cr "$APP"
IDENTITY="${VELTORET_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP/Contents/Frameworks/VLCKit.framework"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements Resources/Veltoret.entitlements "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p dist
rm -rf dist/Veltoret.app
ditto "$APP" dist/Veltoret.app
xattr -cr dist/Veltoret.app 2>/dev/null || true
echo "Built dist/Veltoret.app ($VERSION, build $BUILD, $CONFIG)"
