#!/bin/zsh
# Builds MyNotch.app (no Xcode needed — Command Line Tools are enough).
#   ./scripts/build.sh            → build/MyNotch.app
#   ./scripts/build.sh install    → also copies to /Applications and launches it
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
APP="$ROOT/build/MyNotch.app"
VERSION="1.0.3"
BUILD_NUM=$(date +%Y%m%d%H%M)

echo "▸ Compiling Swift (release)…"
swift build -c release --arch arm64 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | grep -v "^$" || true
BIN="$ROOT/.build/arm64-apple-macosx/release/MyNotch"
[[ -x "$BIN" ]] || { echo "✗ Swift build failed"; swift build -c release --arch arm64; exit 1; }

echo "▸ Compiling media bridge…"
mkdir -p "$ROOT/.build/bridge"
clang -dynamiclib -fobjc-arc -O2 -mmacosx-version-min=14.0 -arch arm64 -arch x86_64 \
  -framework Foundation -o "$ROOT/.build/bridge/libMediaBridge.dylib" "$ROOT/Bridge/MediaBridge.m"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MyNotch"
cp "$ROOT/.build/bridge/libMediaBridge.dylib" "$APP/Contents/Resources/"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] || swift "$ROOT/scripts/make_icon.swift" "$ROOT/Resources" >/dev/null
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MyNotch</string>
  <key>CFBundleDisplayName</key><string>MyNotch</string>
  <key>CFBundleIdentifier</key><string>com.vinay.mynotch</string>
  <key>CFBundleExecutable</key><string>MyNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUM</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.vinay.mynotch</string>
    <key>CFBundleURLSchemes</key><array><string>mynotch</string></array>
  </dict></array>
  <key>NSCalendarsUsageDescription</key><string>MyNotch shows your agenda and meeting join buttons in the notch.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>MyNotch shows your agenda and meeting join buttons in the notch. It never changes your calendars.</string>
  <key>NSCameraUsageDescription</key><string>MyNotch shows a camera mirror only while you are looking at the Mirror tool. Nothing is recorded.</string>
  <key>NSLocationUsageDescription</key><string>MyNotch uses your approximate location for local weather. You can type a city instead.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>MyNotch uses your approximate location for local weather. You can type a city instead.</string>
  <key>NSAppleEventsUsageDescription</key><string>MyNotch can control media playback.</string>
</dict>
</plist>
PLIST

echo "▸ Signing (ad-hoc)…"
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/libMediaBridge.dylib"
codesign --force --sign - --timestamp=none --identifier com.vinay.mynotch -r='designated => identifier "com.vinay.mynotch"' "$APP"
codesign --verify --deep --strict "$APP" && echo "✓ Built $APP"

if [[ "${1:-}" == "install" ]]; then
  echo "▸ Installing to /Applications…"
  pkill -x MyNotch 2>/dev/null || true
  sleep 0.5
  rm -rf /Applications/MyNotch.app
  cp -R "$APP" /Applications/
  open /Applications/MyNotch.app
  echo "✓ Installed and launched"
fi
