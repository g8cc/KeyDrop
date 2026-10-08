#!/bin/bash
# 一键发版:跑测试 → bump Info.plist → make release 出包 → commit → push → GitHub Release
# (GitHub Release 就是自动更新源:Updater 比较 releases/latest 的 tag 与本机版本号)
#
# 用法:
#   ./make-release.sh                          # 补丁号自动 +1(1.4.48 → 1.4.49)
#   ./make-release.sh 1.5.0 -m "fix: 说明"      # 指定版本 + 提交/发布说明
#   ./make-release.sh -m "..." Sources/Core.swift TestSuite/CoreTests.swift
#
# 除版本号外的位置参数 = 本次一起提交的跟踪文件;不传则只提交 Info.plist。
# 工作区里存在「未列入」的已改动跟踪文件会直接中止 —— 避免漏发或误提交。
# 环境变量:SKIP_TESTS=1 跳过 make test(仅在刚跑过测试后用)
set -euo pipefail
cd "$(dirname "$0")"

die() { echo "✗ $*" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || die "需要 GitHub CLI: brew install gh && gh auth login"
gh auth status >/dev/null 2>&1 || die "gh 未登录 github.com"

VERSION=""
NOTES=""
FILES=()
while [ $# -gt 0 ]; do
    case "$1" in
        -m|--notes)
            [ $# -ge 2 ] || die "-m 后面需要说明文本"
            NOTES="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,15p' "$0"; exit 0 ;;
        -*)
            die "未知选项: $1" ;;
        *)
            if [ -z "$VERSION" ] && printf '%s' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
                VERSION="$1"
            else
                FILES+=("$1")
            fi
            shift ;;
    esac
done

CURRENT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
if [ -z "$VERSION" ]; then
    VERSION=$(printf '%s' "$CURRENT" | awk -F. '{ $3 += 1; printf "%d.%d.%d", $1, $2, $3 }')
fi
[ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | head -1)" = "$CURRENT" ] || \
    die "版本 $VERSION 低于当前 $CURRENT,不回退发布"
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    die "本地已有 tag v$VERSION"
fi
if gh release view "v$VERSION" >/dev/null 2>&1; then
    die "GitHub 已有 release v$VERSION(要重发先删掉它,或换版本号)"
fi

# 提交范围校验:允许 Info.plist + 显式列出的文件;其余已改动的跟踪文件一律拦下
ALLOWED="Info.plist"
for f in ${FILES[@]+"${FILES[@]}"}; do
    [ -e "$f" ] || die "文件不存在: $f"
    ALLOWED="$ALLOWED
$f"
done
UNPLANNED=""
while IFS= read -r changed; do
    [ -n "$changed" ] || continue
    printf '%s\n' "$ALLOWED" | grep -qxF "$changed" || UNPLANNED="$UNPLANNED
  $changed"
done <<EOF
$(git diff HEAD --name-only)
EOF
if [ -n "$UNPLANNED" ]; then
    die "以下已改动文件不在本次提交范围,请把它们作为位置参数传入(或先自行提交/还原):$UNPLANNED"
fi

echo "[1/5] 测试…"
if [ "${SKIP_TESTS:-0}" = "1" ]; then
    echo "  SKIP_TESTS=1,跳过"
else
    make test >/dev/null || die "测试未通过,已中止发版"
    echo "  ✓ 全部通过"
fi

echo "[2/5] 版本号 $CURRENT → $VERSION"
if [ "$VERSION" != "$CURRENT" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Info.plist
fi

echo "[3/5] 出包(zip 给已装用户的自动更新,dmg 给新用户拖动安装)…"
make release >/dev/null || die "打包失败"
ZIP="dist/KeyDrop-v$VERSION.zip"
DMG="dist/KeyDrop-v$VERSION.dmg"
[ -f "$ZIP" ] || die "缺少 $ZIP(Updater 只认 KeyDrop-v<版本>.zip)"
[ -f "$DMG" ] || die "缺少 $DMG"

if [ -z "$NOTES" ]; then
    NOTES="chore: 发布新版本"
fi

echo "[4/5] 提交并推送…"
git add Info.plist ${FILES[@]+"${FILES[@]}"}
if git diff --cached --quiet; then
    echo "  工作区无待提交改动(上次已提交),跳过 commit"
else
    git commit -m "$NOTES (v$VERSION)"
fi
BRANCH=$(git rev-parse --abbrev-ref HEAD)
git push origin "$BRANCH"

echo "[5/5] 创建 GitHub Release v${VERSION}…"
gh release create "v$VERSION" "$ZIP" "$DMG" \
    --title "KeyDrop v$VERSION" \
    --notes "$(printf '%s\n\n安装:新用户下载 .dmg 拖进 Applications(直接双击运行会触发 App Translocation,自更新静默失效)。\n已安装用户:下次启动或菜单「检查更新…」即可自动升级(12 小时节流)。' "$NOTES")"

echo "完成: $(gh release view "v$VERSION" --json url -q .url)"
