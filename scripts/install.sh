#!/bin/bash
# 눈 내리는 맥 (SnowMac) one-line installer.
#
#   curl -fsSL https://raw.githubusercontent.com/Kairumu/christmas.mac/main/scripts/install.sh | bash
#
# Downloads the latest release zip with curl (curl'd files never receive the
# com.apple.quarantine attribute, so Gatekeeper's unsigned-app block never
# triggers), unpacks it into /Applications, and launches the app.
set -euo pipefail

REPO="Kairumu/christmas.mac"
URL="https://github.com/$REPO/releases/latest/download/SnowMac.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "눈 내리는 맥 다운로드 중..."
curl -fSL --progress-bar "$URL" -o "$TMP/SnowMac.zip"

echo "설치 중..."
ditto -x -k "$TMP/SnowMac.zip" "$TMP/unpacked"
rm -rf /Applications/SnowMac.app
ditto "$TMP/unpacked/SnowMac.app" /Applications/SnowMac.app

echo "실행!"
open /Applications/SnowMac.app
echo "설치 완료 — 메뉴 막대의 눈송이 아이콘에서 시작하세요. ⛄"
