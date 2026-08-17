#!/bin/bash
# 制作可分发的 zip:release 构建 → bundle → ad-hoc 签名 → 压缩
set -e
cd "$(dirname "$0")"

APP=KeyDrop
DIST=dist
APP_BUNDLE="$DIST/$APP.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist 2>/dev/null || echo "1.0.0")
OUT="$DIST/$APP-$VERSION.zip"

echo "[1/4] release 构建..."
swift build -c release

echo "[2/4] 组装 bundle..."
rm -rf "$APP_BUNDLE" "$DIST/K.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp .build/release/KeyDrop "$APP_BUNDLE/Contents/MacOS/KeyDrop"

echo "[3/4] ad-hoc 签名..."
codesign --force --sign - "$APP_BUNDLE"
codesign -dv "$APP_BUNDLE" 2>&1 | grep -i "Signature\|Identifier" || true

echo "[4/4] 压缩..."
rm -f "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$OUT"
echo "完成: $OUT ($(du -h "$OUT" | cut -f1))"
echo "对方打开被拦时,右键 → 打开,或终端执行:"
echo "  xattr -dr com.apple.quarantine \"\$HOME/Downloads/$APP-$VERSION.zip\"  # 解压前"
