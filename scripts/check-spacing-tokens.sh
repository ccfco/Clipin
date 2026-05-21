#!/bin/bash
#
# Clipin 间距 / 圆角 token 守卫
# ─────────────────────────────────────────────────────────────
# 作为 Xcode 构建阶段运行（project.yml → preBuildScripts）：扫描 Swift 源码，
# 发现硬编码的 padding / spacing / cornerRadius 数字字面量就让构建失败，
# 强制全 app 间距与圆角走 ClipinChrome 设计 token（见 CLAUDE.md「决策」）。
#
# 也可手动运行：./scripts/check-spacing-tokens.sh
#
# 豁免：确属渲染微调、必须用字面量的行，加行内注释  // spacing-exempt
#
# 为什么不用 git pre-commit：本机 core.hooksPath 被全局占用（root 管的全局
# hooks），仓库级 git 钩子会绕过那套全局钩子，故改用构建期检查，零 git 改动。
#
set -uo pipefail

repo_root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
src_dir="$repo_root/Clipin"

# 魔数模式：
#   .padding(数字              →  .padding(8)
#   .padding(.边, 数字         →  .padding(.top, 6)
#   .cornerRadius(数字         →  .cornerRadius(14)            （SwiftUI modifier）
#   cornerRadius :/= 数字      →  cornerRadius: 14 / = 14      （参数 / CALayer 属性）
#   spacing: 非零数字          →  spacing: 8   （spacing: 0 = 无间隔，合法放行）
pattern='\.padding\([0-9]|\.padding\(\.[a-z]+, *[0-9]|\.cornerRadius\([0-9]|cornerRadius *[:=] *[0-9]|spacing: *[1-9]'

violations=0

while IFS= read -r file; do
    while IFS=: read -r lineno rawtext; do
        [ -z "${lineno:-}" ] && continue
        # 显式豁免
        case "$rawtext" in *spacing-exempt*) continue ;; esac
        # 去掉行尾注释后若仍命中，才是真违规（命中只在注释里 → 放行）
        code="${rawtext%%//*}"
        printf '%s\n' "$code" | grep -qE "$pattern" || continue
        echo "${file}:${lineno}: error: 硬编码间距/圆角字面量，请改用 ClipinChrome 设计 token（gap / groupGap / cornerTile / cornerControl / cornerSurface / cornerShell）。渲染微调可加行内注释 // spacing-exempt 豁免。"
        violations=$((violations + 1))
    done < <(grep -nE "$pattern" "$file" 2>/dev/null || true)
done < <(find "$src_dir" -name '*.swift' -type f -not -path '*/Generated/*')

if [ "$violations" -gt 0 ]; then
    echo "error: 发现 ${violations} 处硬编码间距/圆角字面量，构建中止。全 app 间距/圆角由 ClipinChrome.edge 单一旋钮派生，详见 CLAUDE.md「决策」。"
    exit 1
fi

echo "间距 token 守卫：通过（无硬编码间距/圆角字面量）。"
exit 0
