#!/bin/bash
# 发布新版本:bump Info.plist → 打包 zip → 创建 GitHub Release(更新源)
# 用法: ./make-release.sh [版本号]   # 默认取 Info.plist 当前版本
# 示例: ./make-release.sh 1.1.0
set -e
cd "$(dirname "$0")"

if ! command -v gh >/dev/null 2>&1; then
    echo "需要 GitHub CLI(gh) 且已登录: brew install gh && gh auth login" >&2
    exit 1
fi

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
fi

echo "[1/3] 更新 Info.plist 版本 → $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Info.plist

echo "[2/3] 打包 dist/KeyDrop-$VERSION.zip"
./make-dist.sh

ZIP="dist/KeyDrop-$VERSION.zip"
echo "[3/3] 创建 GitHub Release v$VERSION"
gh release create "v$VERSION" "$ZIP" \
    --title "KeyDrop v$VERSION" \
    --notes "KeyDrop v$VERSION

安装: 下载 KeyDrop-$VERSION.zip 解压后拖入 Applications
已在运行的应用会在下次启动时提示更新"
echo "完成: https://github.com/g8cc/KeyDrop/releases/tag/v$VERSION"