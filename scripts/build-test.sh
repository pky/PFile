#!/bin/sh
set -e

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
XCODEBUILD=$DEVELOPER_DIR/usr/bin/xcodebuild
SIMCTL=$DEVELOPER_DIR/usr/bin/simctl
WORKSPACE=PFile.xcworkspace
SCHEME=PFile
SIM_NAME="iPad mini (A17 Pro)"

# Simulator を起動
echo ">>> Simulator を起動..."
SIM_UDID=$($SIMCTL list devices available | grep "$SIM_NAME" | grep -oE '[A-F0-9-]{36}' | head -1)
$SIMCTL boot "$SIM_UDID" 2>/dev/null || true

# ビルド + テスト
echo ">>> ビルド + テスト実行..."
$XCODEBUILD \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$SIM_UDID" \
  -configuration Debug \
  build test

echo ">>> 完了"
