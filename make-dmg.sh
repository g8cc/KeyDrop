#!/bin/bash
# 制作可分发的 DMG:release 构建 → bundle → ad-hoc 签名 → dmg(带 Applications 拖拽)
set -e
cd "$(dirname "$0")"

APP=KeyDrop
DIST=dist
APP_BUNDLE="$DIST/$APP.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist 2>/dev/null || echo "1.0.0")
OUT="$DIST/$APP-$VERSION.dmg"
STAGING="$DIST/dmg-staging"

echo "[1/4] release 构建..."
swift build -c release

echo "[2/4] 组装 bundle..."
rm -rf "$APP_BUNDLE" "$DIST/K.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp .build/release/KeyDrop "$APP_BUNDLE/Contents/MacOS/KeyDrop"
codesign --force --sign - "$APP_BUNDLE"

echo "[3/4] 组装 dmg 目录..."
rm -rf "$STAGING" "$OUT"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "[4/4] 生成 dmg..."
hdiutil create -volname "KeyDrop" -srcfolder "$STAGING" -ov -format UDZO "$OUT" >/dev/null
rm -rf "$STAGING"
echo "完成: $OUT ($(du -h "$OUT" | cut -f1))"
echo "对方打开被拦时,右键 → 打开,或终端执行:"
echo "  xattr -dr com.apple.quarantine \"\$HOME/Downloads/$APP-$VERSION.dmg\""