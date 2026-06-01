#!/usr/bin/env bash
#
# 一次性清理：修复前被「文件图标误判」收进库的 image 历史条目。
#
# 背景：Finder 复制 zip/文件夹/文档时，NSPasteboard 会附带该文件的图标/缩略图(image
# flavor)+ file-url，旧采集逻辑「有 image flavor 就当图片」把它们误存成了 image
# （列表显示「图片·访达 (1024×1024)」，缩略图其实是文件夹/文件图标）。采集逻辑已修复，
# 新复制不再误判；此脚本只清理修复前留下的旧脏数据。
#
# 删除是不可撤销的（连同缓存图一起删），所以分两步：先 scan 看清单、人工确认，再 delete。
# DB 外键 ON DELETE CASCADE + FTS AFTER DELETE 触发器会自动清 representations 与 FTS 索引，
# 脚本只需额外删磁盘上的缓存 PNG。
#
# 用法：
#   ./scripts/cleanup-misclassified-images.sh                 # 扫描列出候选（不改动）
#   ./scripts/cleanup-misclassified-images.sh delete <id...>  # 删除指定条目（id 可用前缀）
#
# 注意：delete 前请先退出 Clipin.app，避免与运行中的 app 抢 DB 写锁。
set -euo pipefail

DB="$HOME/Library/Application Support/Clipin/clipin.db"

if [[ ! -f "$DB" ]]; then
  echo "找不到数据库：$DB" >&2
  exit 1
fi

scan() {
  echo "数据库：$DB"
  echo
  echo "== 候选 A：image 且带 public.file-url（复制时确有 file-url，很可能是文件图标误判）=="
  echo "   注意：iPhone 隔空复制图片 / 复制图片文件也会落在这里且是真图片，务必逐条 Read 缓存图确认！"
  sqlite3 -header -column "$DB" "
    SELECT ci.id, ci.source_name AS src, ci.image_width||'x'||ci.image_height AS wh, ci.image_path
    FROM clip_items ci
    JOIN clip_representations r ON r.item_id = ci.id AND r.uti = 'public.file-url'
    WHERE ci.clip_type = 'image'
    GROUP BY ci.id
    ORDER BY ci.created_at DESC;"
  echo
  echo "== 候选 B：来源为「访达」(Finder) 的 image（Finder 不产生真图片复制；但可能混入窗口截图，"
  echo "   请对每条用 Read 打开 image_path 肉眼确认是不是文件图标，再决定删不删）=="
  sqlite3 -header -column "$DB" "
    SELECT ci.id, ci.source_name AS src, ci.image_width||'x'||ci.image_height AS wh, ci.image_path
    FROM clip_items ci
    WHERE ci.clip_type = 'image' AND ci.source_name = '访达'
    ORDER BY ci.created_at DESC;"
  echo
  echo "确认要删的条目后：$0 delete <id...>（id 可填上面任意前缀；删除前请退出 Clipin.app）"
}

# 把一个 id 前缀解析成唯一完整 id；匹配 0 条或多条都报错退出。
resolve_id() {
  local prefix="$1" matches
  # 防 SQL 注入 + 防误操作：合法 id 是 UUID，前缀只可能含十六进制与连字符；
  # 含引号/分号/空格等一律拒绝，杜绝把命令行参数拼进 SQL 造成多语句注入。
  if [[ ! "$prefix" =~ ^[0-9a-fA-F-]+$ ]]; then
    echo "  ✗ 非法 id 前缀 '$prefix'（只允许十六进制与连字符），跳过" >&2
    return 1
  fi
  matches=$(sqlite3 "$DB" "SELECT id FROM clip_items WHERE id LIKE '${prefix}%';")
  local count
  count=$(printf '%s\n' "$matches" | grep -c . || true)
  if [[ "$count" -eq 0 ]]; then
    echo "  ✗ 前缀 '$prefix' 没匹配到任何条目，跳过" >&2
    return 1
  elif [[ "$count" -gt 1 ]]; then
    echo "  ✗ 前缀 '$prefix' 匹配到 $count 条（不唯一），跳过；请用更长前缀：" >&2
    printf '      %s\n' $matches >&2
    return 1
  fi
  printf '%s' "$matches"
}

delete() {
  if [[ $# -eq 0 ]]; then
    echo "用法：$0 delete <id...>" >&2
    exit 1
  fi
  for prefix in "$@"; do
    local id
    if ! id=$(resolve_id "$prefix"); then
      continue
    fi
    echo "删除 $id"
    # 收集要删的磁盘文件：image_path + attachment_paths（JSON 数组）里的每个非空路径
    local img attach
    img=$(sqlite3 "$DB" "SELECT COALESCE(image_path,'') FROM clip_items WHERE id='$id';")
    attach=$(sqlite3 "$DB" "SELECT COALESCE(attachment_paths,'') FROM clip_items WHERE id='$id';")

    # 先删 DB 行：PRAGMA foreign_keys=ON 必须和 DELETE 在同一次 sqlite3 调用(=同一连接)——
    # sqlite3 CLI 默认 foreign_keys=OFF，不开的话 ON DELETE CASCADE 不触发会留下孤儿
    # representations（app 端 rusqlite 连接已开 FK，仅独立 CLI 需自己开）。
    # FTS 由 AFTER DELETE 触发器同步，不依赖 FK。
    sqlite3 "$DB" "PRAGMA foreign_keys=ON; DELETE FROM clip_items WHERE id='$id';"

    # 再删磁盘缓存图（DB 删除不会动文件系统）
    if [[ -n "$img" && -f "$img" ]]; then
      rm -f "$img" && echo "  · 删缓存图 $img"
    fi
    if [[ -n "$attach" ]]; then
      # attachment_paths 形如 ["/a.png","/b.png"]，抽出每个路径
      printf '%s' "$attach" \
        | grep -oE '"[^"]+"' \
        | sed 's/^"//; s/"$//' \
        | while IFS= read -r p; do
            [[ -n "$p" && -f "$p" ]] && rm -f "$p" && echo "  · 删附件图 $p"
          done
    fi
  done
  echo "完成。重新打开 Clipin.app 即可。"
}

cmd="${1:-scan}"
case "$cmd" in
  scan) scan ;;
  delete) shift; delete "$@" ;;
  *) echo "未知命令：$cmd（支持 scan / delete）" >&2; exit 1 ;;
esac
