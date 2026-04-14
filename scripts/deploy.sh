#!/bin/bash
set -euo pipefail

# 构建并部署 Clipin 到 /Applications
# 用自定义 designated requirement 签名，让 TCC 按 bundle ID 匹配而非 CDHash
# 这样更新二进制后辅助功能权限不会丢失

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DEST_APP="/Applications/Clipin.app"
BUNDLE_ID="com.ccfco.Clipin"

cd "$PROJECT_ROOT"

# 关闭旧进程
pkill -x Clipin 2>/dev/null && sleep 1 || true

# 构建到 DerivedData（默认路径，避免自定义路径的扩展属性问题）
echo "Building..."
xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release build -quiet

# 找到构建产物
BUILT_APP=$(xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Release \
    -showBuildSettings 2>/dev/null | grep -m1 "BUILT_PRODUCTS_DIR" | awk '{print $3}')/Clipin.app

if [ ! -d "$BUILT_APP" ]; then
    echo "Build product not found."
    exit 1
fi

# owner 不匹配时用 osascript 弹图形授权对话框删除并重建（无需 TTY）
if [ -d "$DEST_APP" ] && [ "$(stat -f '%Su' "$DEST_APP")" != "$(whoami)" ]; then
    echo "Removing old app (owned by $(stat -f '%Su' "$DEST_APP"), requesting admin privileges)..."
    osascript -e "do shell script \"rm -rf '$DEST_APP'\" with administrator privileges"
fi

# 增量同步
rsync -a --delete "$BUILT_APP/" "$DEST_APP/"

# 清除扩展属性（防止 codesign 报 resource fork 错误）
xattr -cr "$DEST_APP"

# 用自定义 designated requirement 重新签名
REQ_FILE=$(mktemp)
echo "designated => identifier \"$BUNDLE_ID\"" | csreq -r- -b "$REQ_FILE"
codesign --force --sign - -r "$REQ_FILE" "$DEST_APP"
rm -f "$REQ_FILE"

# 启动
open "$DEST_APP"
echo "Done."
