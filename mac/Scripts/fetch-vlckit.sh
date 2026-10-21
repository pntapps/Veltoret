#!/bin/bash
# Downloads VLCKit (LibVLC for macOS, LGPL-2.1) into Vendor/VLCKit.xcframework. Not committed (400 MB).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="3.7.3-319ed2c0-79128878"
[ -d Vendor/VLCKit.xcframework ] && { echo "VLCKit already present"; exit 0; }
tmp=$(mktemp -d)
curl -fSL -o "$tmp/vlckit.tar.xz" "https://download.videolan.org/pub/cocoapods/prod/VLCKit-$VERSION.tar.xz"
tar -xJf "$tmp/vlckit.tar.xz" -C "$tmp"
mkdir -p Vendor
mv "$tmp/VLCKit - binary package/VLCKit.xcframework" Vendor/
cp "$tmp/VLCKit - binary package/COPYING.txt" Vendor/VLCKit-COPYING.txt
rm -rf "$tmp"
echo "VLCKit $VERSION ready"
