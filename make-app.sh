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
# 优先用本地固定证书:ad-hoc 签名(-)每次重签指纹都变,macOS TCC 把它当新 App,
# 之前的文件访问授权全部作废 → 每次 make app 后都重新弹「文稿/其他 App 数据」
# 隐私弹窗。证书缺失时自动生成(make-cert.sh,免 GUI 免管理员);生成失败仍回退 ad-hoc
"./make-cert.sh" || true
if security find-identity -v -p codesigning 2>/dev/null | grep -q "KeyDropLocal"; then
    codesign --force --sign "KeyDropLocal" "$APP_BUNDLE"
else
    codesign --force --sign - "$APP_BUNDLE"
fi

echo "[4/4] 安装到 $INSTALL ..."
rm -rf "$INSTALL"
cp -R "$APP_BUNDLE" "$INSTALL"

pkill -f "$APP.app" 2>/dev/null || true
# 等旧进程完全退出(最多 5s):进程残留时 LaunchServices 可能拒绝/静默丢弃新实例
for _ in $(seq 1 10); do
    pgrep -f "$APP.app" >/dev/null 2>&1 || break
    sleep 0.5
done
if pgrep -f "$APP.app" >/dev/null 2>&1; then
    pkill -9 -f "$APP.app" 2>/dev/null || true
    sleep 0.3
fi

echo "完成: $INSTALL"

echo "启动: open $INSTALL"
open "$INSTALL"

# 启动验证(最多 5s),失败自动重试一次
for _ in $(seq 1 10); do
    pgrep -f "$APP.app/Contents/MacOS" >/dev/null 2>&1 && break
    sleep 0.5
done
if pgrep -f "$APP.app/Contents/MacOS" >/dev/null 2>&1; then
    echo "✓ 新版本已启动并运行"
else
    echo "启动验证失败,重试一次..."
    open "$INSTALL"
    sleep 2
    if pgrep -f "$APP.app/Contents/MacOS" >/dev/null 2>&1; then
        echo "✓ 新版本已启动(重试成功)"
    else
        echo "✗ 启动失败,请手动执行: open $INSTALL" >&2
        exit 1
    fi
fi
