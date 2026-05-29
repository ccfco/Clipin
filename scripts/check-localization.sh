#!/bin/bash
#
# Clipin 本地化守卫
# ─────────────────────────────────────────────────────────────
# 作为 Xcode 构建阶段运行（project.yml → preBuildScripts），两道检查：
#
#   ① strings 自检：zh-Hans 与 en 的 key 集合必须相等、各自无重复 key。
#      （key 不对齐 = 某语言静默漏翻；重复 key = Xcode 警告 + 改一处漏一处）
#
#   ② 代码字面量缺 key：扫描 Swift 里 Text("…")/Button("…")/Label("…")/
#      LocalizedStringKey("…")/.help("…") 的字符串字面量——SwiftUI 会把它当 key
#      查表，若 Localizable.strings 没有对应 key，中文界面就会 fallback 显示英文。
#      这正是「改了文案忘了同步 key」漏翻的根因，在构建期挡住。
#
#      扫三种文案位置（缺一就会漏翻）：
#        · 首参字面量    Text("Hi") / .help("Copy")
#        · 三元两分支    Text(cond ? "Show raw" : "Pretty")   ← 两分支都是字面量才认
#      扫之前先抹掉非文案参数槽：systemImage:/systemName:（SF Symbol 名）、comment:
#      （NSLocalizedString 注释）——它们不是用户可见文案，扫到会误判漏翻。只认
#      「? "A" : "B"」这种两分支皆字面量的三元，故 Text(fmt(x,"yyyy")) 这类格式串
#      不会被误判成文案。
#
# 也可手动运行：./scripts/check-localization.sh
#
# 豁免（确属不译的技术术语/品牌名/verbatim 文案）：
#   - 通用不译词加进下面的 allowlist 正则
#   - 个别行加行内注释  // l10n-exempt
#
# 为什么不用 git pre-commit：与 check-spacing-tokens.sh 同理，本机全局
# hooksPath 被占用，改用构建期检查，零 git 改动。
#
set -uo pipefail

repo_root="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
src_dir="$repo_root/Clipin"
zh="$src_dir/Resources/zh-Hans.lproj/Localizable.strings"
en="$src_dir/Resources/en.lproj/Localizable.strings"

errors=0

extract_keys() { grep -oE '^[[:space:]]*"([^"\\]|\\.)*"' "$1" | sed -E 's/^[[:space:]]*//' | sort; }

# ── ① strings 自检 ─────────────────────────────────────────────
for f in "$zh" "$en"; do
    dups=$(grep -oE '^[[:space:]]*"([^"\\]|\\.)*"' "$f" | sed -E 's/^[[:space:]]*//' | sort | uniq -d)
    if [ -n "$dups" ]; then
        echo "${f}: error: 重复定义的 key（删到只剩一处）:"
        printf '  %s\n' $dups
        errors=$((errors + 1))
    fi
done

only_zh=$(comm -23 <(extract_keys "$zh") <(extract_keys "$en"))
only_en=$(comm -13 <(extract_keys "$zh") <(extract_keys "$en"))
if [ -n "$only_zh" ]; then
    echo "error: 以下 key 只在 zh-Hans 有、en 缺失（补到 en.lproj）:"
    printf '  %s\n' "$only_zh"
    errors=$((errors + 1))
fi
if [ -n "$only_en" ]; then
    echo "error: 以下 key 只在 en 有、zh-Hans 缺失（补到 zh-Hans.lproj）:"
    printf '  %s\n' "$only_en"
    errors=$((errors + 1))
fi

# ── ② 代码字面量缺 key ─────────────────────────────────────────
# 不译白名单：技术术语 / 品牌名 / 平台名 / 单符号键名。整词匹配。
allowlist='^(Clipin|JSON|HTML|RTF|XML|CSV|URL|URLs|OCR|UI|GitHub|iCloud|Dropbox|macOS|iOS|TUI|Issues|Releases|Esc|Tab|Space|Home|End)$'

zh_keys_file=$(mktemp) || { echo "error: 无法创建临时文件（mktemp 失败）"; exit 1; }
trap 'rm -f "$zh_keys_file"' EXIT
grep -oE '^[[:space:]]*"([^"\\]|\\.)*"' "$zh" | sed -E 's/^[[:space:]]*"//; s/"$//' > "$zh_keys_file"

# 文案载体：这些调用里的字符串字面量应是可翻译文案。.help 单独带前导点。
call_re='(Text|Button|Label|LocalizedStringKey)\(|\.help\('

while IFS= read -r file; do
    while IFS=: read -r lineno rawtext; do
        [ -z "${lineno:-}" ] && continue
        case "$rawtext" in *l10n-exempt*) continue ;; esac
        # 先抹掉非文案参数槽（SF Symbol 名 / NSLocalizedString 注释），其值可能是
        # 字面量或三元，统一吃到行尾的 , 或 ) 之前，避免被当成漏翻文案。
        cleaned=$(printf '%s' "$rawtext" \
            | sed -E 's/(systemImage|systemName|image|comment)[[:space:]]*:[[:space:]]*("([^"\]|\\.)*"|[^,)]*)//g')
        # 该行没有文案载体就跳过（抹槽后再判，防 systemImage 行误入）
        printf '%s' "$cleaned" | grep -qE "$call_re" || continue
        # 首参字面量：紧跟 Text(/Button(/Label(/LocalizedStringKey(/.help( 的引号串
        lits_head=$(printf '%s\n' "$cleaned" \
            | grep -oE "(${call_re})[[:space:]]*\"([^\"\\]|\\.)*\"" \
            | sed -E 's/^[^"]*"//; s/"$//')
        # 三元两分支：? "A" : "B"，两分支都是字面量才提取（已抹掉非文案槽）
        lits_ternary=$(printf '%s\n' "$cleaned" \
            | grep -oE '\?[[:space:]]*"([^"\]|\\.)*"[[:space:]]*:[[:space:]]*"([^"\]|\\.)*"' \
            | grep -oE '"([^"\]|\\.)*"' \
            | sed -E 's/^"//; s/"$//')
        lits=$(printf '%s\n%s' "$lits_head" "$lits_ternary")
        [ -z "$lits" ] && continue
        while IFS= read -r lit; do
            [ -z "$lit" ] && continue
            case "$lit" in *'\('*) continue ;; esac          # 含插值，跳过
            # 不含拉丁字母也不含中文（纯数字/符号，含 ⇥⌘ 等键帽符号）→ 跳过
            printf '%s' "$lit" | grep -qE '[A-Za-z]' \
                || printf '%s' "$lit" | LC_ALL=en_US.UTF-8 grep -q '[一-龥]' \
                || continue
            printf '%s' "$lit" | grep -qE "$allowlist" && continue # 白名单不译词
            grep -qxF "$lit" "$zh_keys_file" || {
                echo "${file}:${lineno}: error: 用户可见文案缺本地化 key: \"${lit}\"（在 zh-Hans 与 en 两个 Localizable.strings 补上；确属不译则加行内 // l10n-exempt 或进 allowlist）"
                errors=$((errors + 1))
            }
        done <<< "$lits"
    done < <(grep -nE "$call_re" "$file" 2>/dev/null || true)
done < <(find "$src_dir" -name '*.swift' -type f -not -path '*/Generated/*')

if [ "$errors" -gt 0 ]; then
    echo "error: 本地化守卫发现 ${errors} 项问题，构建中止。详见 CLAUDE.md「设置页与本地化」。"
    exit 1
fi

echo "本地化守卫：通过（zh/en key 对齐、无重复、用户可见文案均有翻译）。"
exit 0
