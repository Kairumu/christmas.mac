#!/bin/bash
# Build a macOS installer package (.pkg) for SnowMac (눈 내리는 맥).
# Output: build/SnowMac.pkg — installs SnowMac.app into /Applications via
# the standard Installer flow. Apps laid down by Installer.app don't get
# the quarantine xattr, so the installed app launches without the
# unsigned-app "손상됨" dance; only the pkg itself may need right-click →
# 열기 on first open (it's ad-hoc/unsigned).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/SnowMac.app"
PKG="$ROOT/build/SnowMac.pkg"
DIST="$ROOT/build/pkg-distribution.xml"
COMPONENT="$ROOT/build/SnowMac-component.pkg"

[ -d "$APP" ] || { echo "error: $APP not found — run scripts/build_app.sh first" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "1.0.0")

rm -f "$PKG" "$COMPONENT" "$DIST"

pkgbuild \
    --component "$APP" \
    --install-location /Applications \
    --identifier com.kairu.snowmac \
    --version "$VERSION" \
    "$COMPONENT" >/dev/null

# productbuild wrapper for a titled installer UI (welcome pane text).
cat > "$DIST" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>눈 내리는 맥 (SnowMac)</title>
    <welcome language="ko" mime-type="text/plain"><![CDATA[
눈 내리는 맥을 설치합니다.

데스크톱에 눈이 내리고, 창과 Dock 위에 쌓이고,
영서를 소환해 눈을 쓸거나 눈사람을 만들 수 있습니다.

요구 사항: macOS 13 이상 (Apple Silicon / Intel)
설치 후 메뉴 막대의 눈송이 아이콘에서 시작하세요.
]]></welcome>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true"/>
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    <choice id="default" title="SnowMac">
        <pkg-ref id="com.kairu.snowmac"/>
    </choice>
    <pkg-ref id="com.kairu.snowmac" version="$VERSION">SnowMac-component.pkg</pkg-ref>
</installer-gui-script>
EOF

productbuild \
    --distribution "$DIST" \
    --package-path "$ROOT/build" \
    "$PKG" >/dev/null

rm -f "$COMPONENT" "$DIST"
echo "==> done: $PKG ($(du -h "$PKG" | cut -f1 | tr -d ' '))"
