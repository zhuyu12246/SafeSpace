#!/bin/sh
set -e

ROOT="/Users/haowenbai/Desktop/SafeSpace"
APP="$ROOT/SafeSpace.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ROOT/dist"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/assets/AppIcon.icns" ]; then
    cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -f "$ROOT/VMAssets/setup-guest.sh" ]; then
    cp "$ROOT/VMAssets/setup-guest.sh" "$APP/Contents/Resources/setup-guest.sh"
fi

echo "Compiling SafeSpace.app..."
swiftc -module-cache-path /tmp/swift-module-cache \
    -parse-as-library \
    -O \
    "$ROOT/Sources/App/Models.swift" \
    "$ROOT/Sources/App/VMDisplayView.swift" \
    "$ROOT/Sources/App/SandboxVMController.swift" \
    "$ROOT/Sources/App/ContentView.swift" \
    "$ROOT/Sources/App/SafeSpaceApp.swift" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Virtualization \
    -o "$APP/Contents/MacOS/SafeSpace"

echo "Signing SafeSpace.app with Virtualization entitlements..."
codesign --force --deep --sign - --entitlements "$ROOT/SafeSpace.entitlements" "$APP"

echo "Build complete: $APP"
