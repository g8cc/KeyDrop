#!/bin/bash
# 检查 KeyDropLocal 代码签名证书是否可用(只读检查,不生成、不存储任何凭据)。
# 证书缺失时打印手动创建指引——创建证书涉及钥匙串凭据,坚持由用户亲手完成:
# 钥匙串访问 → 证书助理 → 创建证书:名称 KeyDropLocal、证书类型「代码签名」,
# 有效期建议 3650 天。首次构建若弹钥匙串授权,选「始终允许」即可,无密码存储。
set -euo pipefail

IDENT="KeyDropLocal"

probe="$(mktemp)"
if codesign --force --sign "$IDENT" "$probe" 2>/dev/null; then
    rm -f "$probe"
    echo "证书可用: $IDENT"
    exit 0
fi
rm -f "$probe"

cat >&2 <<'EOF'
未检测到可用的 KeyDropLocal 证书 → 本次将回退 ad-hoc 签名(功能不受影响,
但每次重新构建后 macOS 会重新询问「文稿」等文件访问授权)。

一次性创建(约 1 分钟,无密码存储):
  钥匙串访问 → 菜单「钥匙串访问」→ 证书助理 → 创建证书
  名称: KeyDropLocal   身份类型: 自签名根证书   证书类型: 代码签名
  有效期: 3650 天(默认 365 天,到期后需重建,建议改长)
创建后重跑 make app,弹出的钥匙串授权点「始终允许」。
EOF
exit 1
