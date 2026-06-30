#!/bin/bash
# release.sh — Clipin 发版脚本
#
# 用法：
#   ./scripts/release.sh <版本号>     # 例：./scripts/release.sh 0.1.18
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

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "用法：$0 <版本号>  （例：$0 0.1.18）" >&2
    exit 1
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

echo "▸ 更新 project.yml 版本号…"
# 计算 build number：把版本号的点去掉作为整数（0.1.18 → 118）
BUILD_NUMBER=$(echo "$VERSION" | tr -d '.')
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
NOTES=$(./scripts/release-notes.sh 2>/dev/null || echo "")
gh release create "$TAG" \
    "$ZIP_PATH" \
    --title "Clipin $TAG" \
    --notes "$NOTES"

echo "▸ 验证 release 资产可访问（appcast 即将指向的下载 URL）…"
DOWNLOAD_URL="https://github.com/ccfco/Clipin/releases/download/$TAG/$ZIP_NAME"
ASSET_OK=""
for i in 1 2 3 4 5; do
    if curl -fsIL "$DOWNLOAD_URL" >/dev/null 2>&1; then
        ASSET_OK=1
        echo "  ✓ 资产可访问：$DOWNLOAD_URL"
        break
    fi
    echo "  资产暂不可访问，2s 后重试（$i/5）…"
    sleep 2
done
if [ -z "$ASSET_OK" ]; then
    echo "✘ release 资产 5 次探测仍不可访问，已中止——不推送 appcast，避免客户端拿到 404。" >&2
    echo "  appcast 仍为发版前状态（客户端无害）。请检查 release，修好后手动 push appcast，" >&2
    echo "  或回滚：git push origin :$TAG && git tag -d $TAG && gh release delete $TAG --yes" >&2
    exit 1
fi

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
