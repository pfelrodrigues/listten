#!/usr/bin/env bash
# Builds Listten.app from the SwiftPM binary. SwiftPM does not produce app
# bundles, and UserNotifications requires a real bundle to work.
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build/$CONFIG"
APP="$ROOT/.build/Listten.app"
VERSION="$(sed -n 's/.*version = "\(.*\)"/\1/p' "$ROOT/Sources/ListtenCore/Listten.swift")"

swift build -c "$CONFIG" --product listten

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Single binary. A second "listten" here would clobber it: macOS is case-insensitive.
cp "$BUILD/listten" "$APP/Contents/MacOS/Listten"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Listten</string>
  <key>CFBundleIdentifier</key><string>br.com.pyo.listten</string>
  <key>CFBundleName</key><string>Listten</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSMicrophoneUsageDescription</key><string>Listten records your voice during meetings you choose to record.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Listten records other participants during meetings you choose to record.</string>
</dict></plist>
PLIST

codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "$APP"
