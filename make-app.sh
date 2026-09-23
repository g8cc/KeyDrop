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

# 记录旧 pid:重启验证必须确认「旧进程消失 + 新进程出现」,
# 否则 pkill 失效时旧进程会被 pgrep 误判成"新版本已启动"(真实事故 2026-09-24)
OLD_PID="$(pgrep -f "$APP.app/Contents/MacOS" | head -1 || true)"

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

# 启动验证(最多 5s),失败自动重试一次。
# 验证口径必须是「旧 pid 消失 + 新 pid 出现」:只看"有进程在跑"会把没杀掉的
# 旧进程误判成新版本(真实事故 2026-09-24,v1.4.24 发布时重启静默失效)
NEW_PID=""
for _ in $(seq 1 10); do
    NEW_PID="$(pgrep -f "$APP.app/Contents/MacOS" | head -1 || true)"
    if [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ]; then break; fi
    sleep 0.5
done
INSTALLED_VER="$(defaults read "$INSTALL/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"

check_new() {
    [ -n "$NEW_PID" ] && [ "$NEW_PID" != "$OLD_PID" ]
}

if check_new; then
    echo "✓ v$INSTALLED_VER 已启动并运行 (pid $NEW_PID)"
else
    echo "启动验证失败,重试一次..."
    open "$INSTALL"
    sleep 2
    NEW_PID="$(pgrep -f "$APP.app/Contents/MacOS" | head -1 || true)"
    if check_new; then
        echo "✓ v$INSTALLED_VER 已启动(重试成功, pid $NEW_PID)"
    elif [ -n "$NEW_PID" ]; then
        echo "⚠ 运行中的仍是旧进程 (pid $NEW_PID, 旧 $OLD_PID)——重启未生效,请手动退出后重开" >&2
        exit 1
    else
        echo "✗ 启动失败,请手动执行: open $INSTALL" >&2
        exit 1
    fi
fi
