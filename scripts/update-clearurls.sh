#!/usr/bin/env bash
# 从 ClearURLs upstream 拉取最新 tracking 参数规则快照。
#
# ClearURLs 项目地址：https://gitlab.com/ClearURLs/Rules
# 我们用它官方提供的 minify 镜像：https://rules2.clearurls.xyz/data.minify.json
#
# 流程：
# 1. 拉到临时文件，验证是合法 JSON 且 providers 数量合理
# 2. 与当前 Resources/clearurls-rules.json diff，告知规则数量变化
# 3. 不自动覆盖：必须人工 review diff 后再决定是否 commit
#    （ClearURLs 偶尔 schema 微调，自动覆盖 + push 会让线上突然炸）
#
# 用法：
#   ./scripts/update-clearurls.sh          # 拉取并 diff，不覆盖
#   ./scripts/update-clearurls.sh --apply  # diff OK 后直接覆盖到 Resources/
#
# 建议节奏：每月跑一次或 follow GitHub release notification。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$REPO_ROOT/Clipin/Resources/clearurls-rules.json"
TMP_FILE="$(mktemp -t clearurls.XXXXXX.json)"
trap 'rm -f "$TMP_FILE"' EXIT

UPSTREAM_URL="https://rules2.clearurls.xyz/data.minify.json"

echo "→ Fetching ClearURLs rules from $UPSTREAM_URL"
if ! curl -fsSL --max-time 30 -o "$TMP_FILE" "$UPSTREAM_URL"; then
    echo "✗ Failed to download. Check network / upstream availability."
    exit 1
fi

echo "→ Validating JSON structure"
# 用 python3 校验：① 必须是合法 JSON ② 必须有 providers 顶层 key ③ 至少 50 个 provider
NEW_COUNT=$(python3 -c "
import json, sys
try:
    d = json.load(open('$TMP_FILE'))
    providers = d.get('providers', {})
    if not isinstance(providers, dict):
        print('schema error: providers is not dict', file=sys.stderr); sys.exit(1)
    if len(providers) < 50:
        print(f'sanity check failed: only {len(providers)} providers', file=sys.stderr); sys.exit(1)
    print(len(providers))
except Exception as e:
    print(f'JSON parse failed: {e}', file=sys.stderr); sys.exit(1)
")
echo "  ✓ $NEW_COUNT providers"

OLD_COUNT=0
if [[ -f "$TARGET" ]]; then
    OLD_COUNT=$(python3 -c "import json; print(len(json.load(open('$TARGET'))['providers']))" 2>/dev/null || echo "0")
fi
echo "→ Current local: $OLD_COUNT providers; upstream: $NEW_COUNT providers"
echo "  diff: $((NEW_COUNT - OLD_COUNT)) (negative = providers removed upstream)"

NEW_SIZE=$(wc -c < "$TMP_FILE" | tr -d ' ')
OLD_SIZE=$([[ -f "$TARGET" ]] && wc -c < "$TARGET" | tr -d ' ' || echo "0")
echo "  file size: $OLD_SIZE → $NEW_SIZE bytes"

if [[ "${1:-}" == "--apply" ]]; then
    cp "$TMP_FILE" "$TARGET"
    echo "✓ Applied to $TARGET"
    echo "  Don't forget: review with 'git diff' and commit."
else
    DIFF_FILE="$(mktemp -t clearurls-diff.XXXXXX.txt)"
    if [[ -f "$TARGET" ]]; then
        diff <(python3 -c "import json,sys;print(sorted(json.load(open('$TARGET'))['providers'].keys()),sep='\n')") \
             <(python3 -c "import json,sys;print(sorted(json.load(open('$TMP_FILE'))['providers'].keys()),sep='\n')") \
             > "$DIFF_FILE" 2>/dev/null || true
        if [[ -s "$DIFF_FILE" ]]; then
            echo "→ Provider name diff (just keys, not full rule diff):"
            cat "$DIFF_FILE" | head -30
        else
            echo "→ Provider names unchanged (rules may still differ)."
        fi
        rm -f "$DIFF_FILE"
    fi
    echo ""
    echo "Dry-run done. To apply: $0 --apply"
fi
