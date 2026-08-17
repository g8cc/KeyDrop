#!/bin/bash
# 打包 KeyDrop.app:release 构建 → bundle → 签名 → 安装到 ~/Applications
set -e
cd "$(dirname "$0")"

APP=KeyDrop
DIST=dist
APP_BUNDLE="$DIST/$APP.app"
INSTALL="$HOME/Applications/$APP.app"

echo "[1/4] release 构建..."
swift build -c release

echo "[2/4] 组装 bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp .build/release/KeyDrop "$APP_BUNDLE/Contents/MacOS/KeyDrop"

echo "[3/4] 签名..."
codesign --force --sign - "$APP_BUNDLE"

echo "[4/4] 安装到 $INSTALL ..."
rm -rf "$INSTALL"
cp -R "$APP_BUNDLE" "$INSTALL"

pkill -f "$APP.app" 2>/dev/null || true
sleep 0.5

echo "完成: $INSTALL"
echo "启动: open $INSTALL"
