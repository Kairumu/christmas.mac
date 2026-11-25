#!/bin/bash
# Build a drag-to-install DMG for SnowMac (눈 내리는 맥).
# Output: build/SnowMac.dmg — contains the app, an /Applications symlink,
# and a short install guide covering the unsigned-app quarantine step.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/SnowMac.app"
DMG="$ROOT/build/SnowMac.dmg"
STAGE="$ROOT/build/dmg-stage"
VOLNAME="눈 내리는 맥"

[ -d "$APP" ] || { echo "error: $APP not found — run scripts/build_app.sh first" >&2; exit 1; }

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/응용 프로그램"

cat > "$STAGE/설치 안내.txt" <<'EOF'
눈 내리는 맥 (SnowMac) 설치 방법

1. SnowMac.app 을 "응용 프로그램" 폴더로 드래그하세요.
2. 처음 실행할 때 "확인되지 않은 개발자" 또는 "손상됨" 경고가 뜨면,
   터미널을 열고 아래 한 줄을 실행한 뒤 다시 여세요:

   xattr -dr com.apple.quarantine /Applications/SnowMac.app

3. 메뉴 막대의 눈송이 아이콘에서 눈 양 조절, 영서 소환,
   제설차, 배경화면 등을 사용할 수 있습니다.

요구 사항: Apple Silicon Mac, macOS 13 이상
EOF

hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG" >/dev/null

rm -rf "$STAGE"
echo "==> done: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
