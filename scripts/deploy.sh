#!/bin/bash
set -euo pipefail

# 部署 Clipin 到 /Applications，并用稳定的 designated requirement 签名
# 这样更新后辅助功能权限不会丢失（TCC 按 bundle ID 匹配而非 CDHash）

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILT_APP="$HOME/Library/Developer/Xcode/DerivedData/Clipin-fpmuzjvzrzhuifddsfojgglftfvz/Build/Products/Release/Clipin.app"
DEST_APP="/Applications/Clipin.app"
BUNDLE_ID="com.ccfco.Clipin"

if [ ! -d "$BUILT_APP" ]; then
    echo "❌ Build product not found. Run xcodebuild first."
    exit 1
fi

# 关闭旧进程
pkill -x Clipin 2>/dev/null && sleep 1 || true

# 增量同步（不删除 app bundle，保持 TCC 记录）
rsync -a --delete "$BUILT_APP/" "$DEST_APP/"

# 用自定义 designated requirement 重新签名
# 让 TCC 按 identifier 匹配而非 cdhash，更新后权限不丢
REQ_FILE=$(mktemp)
echo "designated => identifier \"$BUNDLE_ID\"" | csreq -r- -b "$REQ_FILE"
codesign --force --sign - -r "$REQ_FILE" "$DEST_APP"
rm -f "$REQ_FILE"

# 启动
open "$DEST_APP"
echo "✅ Deployed to $DEST_APP"
