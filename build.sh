#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
SDK="$(xcrun --show-sdk-path)"
APP="$(pwd)/AppRing.app"
rm -rf "$APP" build; mkdir -p build
# Deployment target 12.0: CGWindowListCreateImage (window thumbnails) is
# marked unavailable when targeting newer macOS, but works fine at runtime.
for arch in arm64 x86_64; do
  xcrun swiftc -O -sdk "$SDK" -target ${arch}-apple-macos12.0 \
    -framework AppKit -framework CoreGraphics -framework ApplicationServices -framework Carbon \
    -o build/AppRing_${arch} \
    main.swift AppDelegate.swift Core/*.swift UI/*.swift
done
xcrun lipo -create -output build/AppRing build/AppRing_arm64 build/AppRing_x86_64
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/AppRing "$APP/Contents/MacOS/AppRing"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep --sign - "$APP" >/dev/null
echo "✓ Built: $APP"
