#!/bin/bash
# release.sh — Clipin 发版脚本
#
# 用法：
#   ./scripts/release.sh <版本号>                        # 例：./scripts/release.sh 0.1.18
#   ./scripts/release.sh <版本号> --notes-file notes.md  # 用综合好的 notes（推荐；不传则自动分类初稿）
#
# 依赖：
#   - xcodegen（brew install xcodegen）
#   - gh（brew install gh，已登录 GitHub）
#   - generate_appcast / sign_update（从 Sparkle release 下载，放到 PATH）
#     快速安装：
#       curl -L https://github.com/sparkle-project/Sparkle/releases/latest/download/Sparkle-latest.tar.xz \
#         | tar xJf - -C /usr/local/bin bin/generate_appcast bin/sign_update
#
# 首次运行前需生成签名密钥（一次性操作）：
#   generate_keys
#   → 把输出的 SUPublicEDKey 填入 Clipin/Resources/Info.plist

set -euo pipefail

# 参数：版本号（位置）+ 可选 --notes-file <路径>。传了 notes 文件就用它作为 release notes
# （推荐：先人工综合好再发），不传则回退到 release-notes.sh 的自动分类初稿。
VERSION=""
NOTES_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --notes-file)
            NOTES_FILE="${2:-}"
            [ -n "$NOTES_FILE" ] || { echo "✘ --notes-file 需要一个路径参数" >&2; exit 1; }
            shift 2 ;;
        --notes-file=*)
            NOTES_FILE="${1#*=}"
            [ -n "$NOTES_FILE" ] || { echo "✘ --notes-file 需要一个路径参数" >&2; exit 1; }
            shift ;;
        -*)
            echo "✘ 未知参数：$1" >&2; exit 1 ;;
        *)
            VERSION="$1"; shift ;;
    esac
done
if [ -z "$VERSION" ]; then
    echo "用法：$0 <版本号> [--notes-file notes.md]  （例：$0 0.1.18）" >&2
    exit 1
fi
if [ -n "$NOTES_FILE" ] && [ ! -f "$NOTES_FILE" ]; then
    echo "✘ notes 文件不存在：$NOTES_FILE" >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RELEASES_DIR="$PROJECT_ROOT/releases"
TAG="v$VERSION"

cd "$PROJECT_ROOT"

echo "▸ 检查工具链…"
for cmd in xcodegen generate_appcast gh; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "缺少 $cmd，请先安装。" >&2; exit 1; }
done

# 先于任何文件改动检查工作树,否则版本号 sed 会和已有的未提交改动混进同一个发布 commit
echo "▸ 前置检查…"
if [ -n "$(git status --porcelain)" ]; then
    echo "✘ 有未提交改动,请先 commit,避免混入发布 commit" >&2; exit 1
fi
if git rev-parse -q --verify "$TAG" >/dev/null 2>&1; then
    echo "✘ tag $TAG 已存在,如需重发请先 git tag -d $TAG" >&2; exit 1
fi

echo "▸ 更新 project.yml 版本号…"
# 计算 build number：major*10000 + minor*100 + patch（0.1.18 → 118；0.2.0 → 200）。
# 不能用 `tr -d '.'`：① "0.1.18"→"0118" 带前导 0，YAML 会当非法八进制解析成浮点 118.0，
# 最终 CFBundleVersion / appcast sparkle:version 都变 "118.0"，客户端 Int("118.0")=nil
# 检不出更新；② "0.2.0"→"020"→20 会小于 "0.1.18"→118，非单调、跨 minor 升级检不出。
# 10# 强制十进制，避免 patch 带前导 0（如 08）被当八进制。
IFS='.' read -r _VMAJ _VMIN _VPAT <<< "$VERSION"
BUILD_NUMBER=$(( 10#${_VMAJ:-0} * 10000 + 10#${_VMIN:-0} * 100 + 10#${_VPAT:-0} ))
sed -i '' \
    -e "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" \
    -e "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $BUILD_NUMBER/" \
    project.yml

echo "▸ 生成 Xcode 项目…"
xcodegen generate --quiet

echo "▸ 构建 Release…"
xcodebuild \
    -project Clipin.xcodeproj \
    -scheme Clipin \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    build -quiet

# 用 sed 取 ` = ` 之后的整行（保留含空格的路径），比 awk '{print $3}' 稳
BUILT_PRODUCTS_DIR=$(xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release \
    -showBuildSettings 2>/dev/null | grep -m1 " BUILT_PRODUCTS_DIR = " | sed 's/.* = //')
BUILT_APP="$BUILT_PRODUCTS_DIR/Clipin.app"
[ -d "$BUILT_APP" ] || { echo "✘ 构建产物不存在：$BUILT_APP" >&2; exit 1; }

echo "▸ 打包 zip…"
mkdir -p "$RELEASES_DIR"
ZIP_NAME="Clipin-$VERSION.zip"
ZIP_PATH="$RELEASES_DIR/$ZIP_NAME"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$BUILT_APP" "$ZIP_PATH"
echo "  → $ZIP_PATH ($(du -sh "$ZIP_PATH" | cut -f1))"

echo "▸ 生成 appcast（EdDSA 签名）…"
# generate_appcast 不支持 --output，固定写入 <archives-dir>/appcast.xml；
# 写完后再复制到仓库根目录供 Sparkle 客户端拉取。
generate_appcast "$RELEASES_DIR" \
    --download-url-prefix "https://github.com/ccfco/Clipin/releases/download/$TAG/"
cp "$RELEASES_DIR/appcast.xml" "$PROJECT_ROOT/appcast.xml"

# ── 发布顺序（原子性红线）────────────────────────────────────
# appcast 一旦推到 main，已安装客户端立刻能拉到它指向的下载 URL。若此时
# release 资产还没上传，客户端会拿到 404，更新链当场断。所以顺序必须是：
#   ① commit 版本号 + tag + push 代码  ② 建 release 上传 zip
#   ③ 验证资产可下载  ④ 最后才 commit + push appcast
# 任一前置步骤失败时，appcast 仍是旧的（指向旧版本），客户端无害——不会 404。

echo "▸ 提交版本号 + 打 tag…"
git add project.yml
git commit -m "chore: 发布 $TAG

【根因/背景】版本迭代
【改动范围】project.yml 版本号 → $VERSION"
git tag "$TAG"

echo "▸ 推送代码 + tag…"
git push
git push origin "$TAG"

echo "▸ 创建 GitHub Release 并上传资产…"
if [ -n "$NOTES_FILE" ]; then
    gh release create "$TAG" \
        "$ZIP_PATH" \
        --title "Clipin $TAG" \
        --notes-file "$NOTES_FILE"
else
    NOTES=$(./scripts/release-notes.sh 2>/dev/null || echo "")
    gh release create "$TAG" \
        "$ZIP_PATH" \
        --title "Clipin $TAG" \
        --notes "$NOTES"
fi

echo "▸ 验证 release 资产可下载（appcast 即将指向的下载 URL）…"
# curl HEAD 对 GitHub Releases 不可靠(不保证与 GET 行为一致,也不保证上传后立即全局可见)。
# 用 gh api 查资产真实状态(state==uploaded 且 size>0),确认后再用 curl HEAD 做一次真实可达性兜底。
DOWNLOAD_URL="https://github.com/ccfco/Clipin/releases/download/$TAG/$ZIP_NAME"
ASSET_OK=""
DELAYS=(5 10 20 30 30 30)
for i in "${!DELAYS[@]}"; do
    STATE="$(gh api "repos/ccfco/Clipin/releases/tags/$TAG" \
        --jq ".assets[] | select(.name==\"$ZIP_NAME\") | .state" 2>/dev/null || true)"
    SIZE="$(gh api "repos/ccfco/Clipin/releases/tags/$TAG" \
        --jq ".assets[] | select(.name==\"$ZIP_NAME\") | .size" 2>/dev/null || true)"
    if [ "$STATE" = "uploaded" ] && [ -n "$SIZE" ] && [ "$SIZE" -gt 0 ]; then
        ASSET_OK=1; echo "  ✓ 资产已就绪（state=uploaded, size=${SIZE}）"; break
    fi
    echo "  资产未就绪（state=${STATE:-unknown}），${DELAYS[$i]}s 后重试（$((i + 1))/${#DELAYS[@]}）…"
    sleep "${DELAYS[$i]}"
done
if [ -z "$ASSET_OK" ]; then
    echo "✘ release 资产轮询 ${#DELAYS[@]} 次仍未就绪，已中止——不推送 appcast，避免客户端拿到 404。" >&2
    echo "  appcast 仍为发版前状态（客户端无害）。请检查 release，修好后手动 push appcast，" >&2
    echo "  或回滚：git push origin :$TAG && git tag -d $TAG && gh release delete $TAG --yes" >&2
    exit 1
fi
if ! curl -fsIL "$DOWNLOAD_URL" >/dev/null 2>&1; then
    echo "✘ gh api 报资产已就绪,但实际 HTTP 请求不可达,已中止——不推送 appcast。" >&2
    echo "  appcast 仍为发版前状态（客户端无害）。请检查 release，修好后手动 push appcast，" >&2
    echo "  或回滚：git push origin :$TAG && git tag -d $TAG && gh release delete $TAG --yes" >&2
    exit 1
fi
echo "  ✓ HTTP 可达性确认通过：$DOWNLOAD_URL"

echo "▸ 推送 appcast（资产已就位，此刻暴露才安全）…"
git add appcast.xml
git commit -m "chore: 更新 appcast $TAG

【根因/背景】发布 $TAG 后更新 Sparkle 更新源，资产已确认可下载
【改动范围】appcast.xml 新增 $TAG EdDSA 签名条目"
git push

echo ""
echo "✅ 发版完成：$TAG"
echo "   release 资产已就位并验证可下载，appcast.xml 已推送到 main。"
echo "   Sparkle 客户端将自动检测到新版本。"
echo ""
echo "清理旧 zip（保留最新两个版本以支持 Sparkle delta）："
echo "  ls releases/*.zip | sort -V | head -n -2 | xargs rm -f"
