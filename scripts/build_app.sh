#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Universal binary: Tahoe (macOS 26) still runs on several Intel Macs, and
# an arm64-only slice simply refuses to launch there.
ARCHES=(--arch arm64 --arch x86_64)
echo "==> swift build -c release (universal)"
swift build -c release "${ARCHES[@]}"

BIN_PATH="$(swift build -c release "${ARCHES[@]}" --show-bin-path)/SnowMac"

APP_DIR="$ROOT_DIR/build/SnowMac.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/SnowMac"
chmod +x "$MACOS_DIR/SnowMac"

# Copy SwiftPM's generated resource bundle into Contents/Resources (the
# standard app-bundle resource location) BEFORE codesign, so it's covered
# by the signature. This must NOT sit loose at the .app's top level: a
# top-level item outside Contents/ makes `codesign --verify --strict` fail
# ("code has no resources but signature indicates they must be present") —
# verified empirically. SwiftPM's generated Bundle.module accessor looks for
# this bundle at Bundle.main.bundleURL (the .app's top level) first, which
# won't find it here; SweeperCharacter.swift falls back to Bundle.main.resourceURL
# (i.e. exactly this location) when that lookup misses.
BUNDLE_NAME="SnowMac_SnowMac.bundle"
BUNDLE_PATH="$(swift build -c release "${ARCHES[@]}" --show-bin-path)/$BUNDLE_NAME"
if [ -d "$BUNDLE_PATH" ]; then
    echo "==> copying resource bundle"
    cp -R "$BUNDLE_PATH" "$RESOURCES_DIR/$BUNDLE_NAME"
else
    echo "==> warning: resource bundle not found at $BUNDLE_PATH" >&2
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SnowMac</string>
    <key>CFBundleIdentifier</key>
    <string>com.kairu.snowmac</string>
    <key>CFBundleName</key>
    <string>눈 내리는 맥</string>
    <key>CFBundleDisplayName</key>
    <string>눈 내리는 맥</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
PLIST

echo "==> codesign (ad-hoc)"
codesign --force --deep -s - "$APP_DIR"

echo "==> done: $APP_DIR"
