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

BUILT_APP=$(xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release \
    -showBuildSettings 2>/dev/null | grep -m1 "BUILT_PRODUCTS_DIR" | awk '{print $3}')/Clipin.app

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

echo "▸ 提交版本更新…"
git add project.yml appcast.xml
git commit -m "chore: 发布 $TAG

【根因/背景】版本迭代
【踩坑记录】无
【改动范围】project.yml 版本号 → $VERSION，appcast.xml 新增 $TAG 条目"

echo "▸ 打 tag…"
git tag "$TAG"

echo "▸ 推送…"
git push
git push origin "$TAG"

echo "▸ 创建 GitHub Release…"
NOTES=$(./scripts/release-notes.sh 2>/dev/null || echo "")
gh release create "$TAG" \
    "$ZIP_PATH" \
    --title "Clipin $TAG" \
    --notes "$NOTES"

echo ""
echo "✅ 发版完成：$TAG"
echo "   appcast.xml 已推送到 main，Sparkle 客户端将自动检测到新版本。"
echo ""
echo "清理旧 zip（保留最新两个版本以支持 Sparkle delta）："
echo "  ls releases/*.zip | sort -V | head -n -2 | xargs rm -f"
