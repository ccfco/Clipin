#!/bin/bash
#
# Clipin 发布 notes 初稿生成器
# ─────────────────────────────────────────────────────────────
# 强制以「上一个 tag .. 目标 ref」的全量 git 区间为唯一真相源，按 commit 类型前缀
# 分类摊开，避免凭印象写 notes 只覆盖最近几个 commit（曾导致 v0.1.11 notes 漏写
# 70 个提交里 60+ 的功能改动——见本脚本存在的原因）。
#
# 用法：
#   ./scripts/release-notes.sh                 # 自动用最新 tag..HEAD
#   ./scripts/release-notes.sh v0.1.10         # v0.1.10..HEAD
#   ./scripts/release-notes.sh v0.1.10 v0.1.11 # 指定两端
#
# 输出是「分类初稿」不是终稿：仍需人工综合——把多个同主题提交合成一条用户向描述、
# 标注加了又删的实验性功能（net 无）、剔除纯内部噪音。综合完用：
#   gh release edit <tag> --notes-file <你整理后的文件>
#
set -euo pipefail

prev="${1:-$(git describe --tags --abbrev=0)}"
cur="${2:-HEAD}"

if ! git rev-parse -q --verify "$prev" >/dev/null; then
    echo "❌ 上一版 ref 不存在：$prev" >&2
    exit 1
fi

range="$prev..$cur"
total=$(git rev-list --count "$range")
repo_slug=$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')

# 按类型前缀分桶。feat/fix 单列；refactor/perf/test/style/build/ci 归「改进与工程」；
# chore/docs/debug 视为噪音，仅计数不进正文。
emit_section() {
    local title="$1" pattern="$2"
    local body
    # grep 无匹配时返回 1，在 set -euo pipefail 下会让整条管道失败、触发 set -e
    # 让脚本中途退出（纯 bugfix 版本区间无 feat 提交，就会卡在第一个 feat section）。
    # || true 把「该类型无提交」这一预期内的空匹配吞掉，body 留空即跳过该 section。
    body=$(git log --no-merges --format='%s' "$range" \
        | grep -E "^($pattern):" \
        | sed -E "s/^($pattern): */- /" || true)
    if [ -n "$body" ]; then
        printf '\n## %s\n\n%s\n' "$title" "$body"
    fi
}

echo "# 发布 notes 初稿：$prev → $cur"
echo ""
echo "> 区间 \`$range\` 共 $total 个提交。以下按类型摊开，**需人工综合**后再作为最终 notes。"

emit_section "新功能（feat）" "feat"
emit_section "修复（fix）" "fix"
emit_section "改进与工程（refactor/perf/test/style/build/ci）" "refactor|perf|test|style|build|ci"

noise=$(git log --no-merges --format='%s' "$range" | grep -cE "^(chore|docs|debug):" || true)
echo ""
echo "## 未计入正文的噪音提交：$noise（chore/docs/debug，通常不进用户向 notes）"

if [ -n "$repo_slug" ]; then
    echo ""
    echo "## Compare"
    echo ""
    echo "[$prev...$cur](https://github.com/$repo_slug/compare/$prev...$cur)"
fi
