# storage.rs 列清单收口设计

## 问题

`storage.rs` 把 `ClipItem` / `ClipListItem` 两种投影的 `SELECT` 列清单**逐字手抄进约 22 条 SQL**:

- `ClipItem`(15 列)出现在 `get_items`、`get_item`、`get_unprocessed_images`、`get_unsized_images`、`export_archive_snapshot`、以及搜索的 4 个函数(raw/pinyin × FTS/LIKE 分支),共约 12 处。
- `ClipListItem`(15 列,含 `substr(...)` preview 表达式)出现在 `get_list_items_with_pinned_filter` 的 4 个分支 + 搜索的 2 个 list 函数各自分支,约 10 处。

解码集中在 `row_to_item` / `row_to_list_item` 两个函数,靠 `row.get(ordinal)` 按列序号取值。问题在于:**这些 decoder 的 ordinal 默默依赖那 ~22 条 SQL 的列顺序完全一致**。加一列要在 22 处字符串里精确插入到同一位置,再改 decoder ordinal;漏一处或错位,整列会静默解码到错误字段——不报错。这正是 CLAUDE.md 当前那条"12 处 SELECT 必须同时改"的高危约定描述的风险,且应对方式是"人肉记得",违反编码原则第 6 条。

## 目标

让"列顺序"只有一个真相源,SQL 投影和 decoder 都从它派生。加列从"改 22 处"降到"改 1 个生成函数 + 1 个 decoder"。

## 非目标

- 不动搜索的 `WHERE` / `ORDER BY` 分支结构,排序语义一字不改(挡 2 的"搜索 SQL 构造器"明确排除)。
- 不动 `INSERT` 写入列清单(`save_item` / `import_item` 的 `(id,content,...)`)——它们是写入投影,列集与顺序和读取投影不同,不属于本次收口。
- 不动 ClipboardViewModel(另开 spec)。

## 方案

### 用函数而非常量

两个变体维度决定了必须用 `fn(prefix)` 而非裸 `const`:

1. **表别名**:搜索的 FTS 分支 `JOIN clip_fts` 时列必须带 `ci.` 前缀消歧;浏览 / `get_item` / 搜索的 LIKE 分支(无 JOIN)用裸列名。
2. **preview 是表达式**:`ClipListItem` 第二列是 `substr(COALESCE(NULLIF(ocr_text,''),content),1,{LIST_PREVIEW_CHARS})`,前缀要钻进表达式内部的 `ocr_text` / `content`。

```rust
/// ClipItem 的 15 列,顺序必须与 row_to_item 的 ordinal 0..14 一一对应。
/// prefix: "" (裸列) 或 "ci." (JOIN clip_fts 消歧)。
fn item_cols(prefix: &str) -> String;

/// ClipListItem 的 15 列(含 preview 表达式,吃 LIST_PREVIEW_CHARS),
/// 顺序必须与 row_to_list_item 的 ordinal 0..14 一一对应。
fn list_item_cols(prefix: &str) -> String;
```

列定义(权威顺序,decoder 跟随):

- `item_cols`: `id, content, clip_type, source_app, source_name, is_pinned, created_at, image_path, char_count, copy_count, first_copied_at, ocr_text, paste_count, alias, attachment_paths`
- `list_item_cols`: `id, <preview 表达式>, clip_type, source_app, source_name, is_pinned, created_at, image_path, char_count, paste_count, copy_count, image_width, image_height, alias, attachment_paths`

> 注意两者列顺序不同(item 是 `copy_count, first_copied_at`,list 是 `paste_count, copy_count`),所以是两个独立函数,不可合并。

### SQL 改为派生

各 `SELECT` 改为 `format!("SELECT {} FROM clip_items WHERE ...", item_cols(prefix))`。搜索 FTS 分支列尾的 `, clip_fts.rank` 由调用点自己 `format!` 追加,**不进**生成函数(它不是数据列,且只有 FTS 分支有;rank 仍固定排在所有数据列之后,ordinal=15)。

调用点前缀映射:

| 调用点 | 前缀 | 带 rank |
|---|---|---|
| `get_items` / `get_item` / `get_unprocessed_images` / `get_unsized_images` / `export_archive_snapshot` | `""` | 否 |
| `get_list_items_with_pinned_filter`(4 分支) | `""` | 否 |
| `query_raw_item_hits` / `query_pinyin_item_hits` — FTS(≥3 字)分支 | `"ci."` | 是 |
| `query_raw_item_hits` / `query_pinyin_item_hits` — LIKE(≤2 字)分支 | `""` | 否 |
| `query_raw_list_hits` / `query_pinyin_list_hits` — FTS 分支 | `"ci."` | 是 |
| `query_raw_list_hits` / `query_pinyin_list_hits` — LIKE 分支 | `""` | 否 |

### decoder 加契约注释

`row_to_item` / `row_to_list_item` 不动逻辑,但加注释把 ordinal 显式绑定到生成函数的列顺序:"改列顺序必须同步改 `item_cols`/`list_item_cols` 与本 decoder 两处"。

## 前置:先补搜索路径测试(安全网)

`storage_tests.rs` 当前对 `search` / `search_list_items` **零覆盖**,收口若错位不会被现有测试抓到。**必须先补、确认绿,再做收口重构。** 补的测试断言两件事:

1. **字段解码正确**:插入已知字段值的条目,搜索取回后逐字段断言值对得上(直接抓 ordinal 错位——这是收口最该防的回归)。
2. **排序与路径覆盖**:构造 is_pinned / paste_count / copy_count / created_at 有区分度的数据,断言顺序符合 `is_pinned > paste_count > rank > copy_count > created_at`;覆盖 FTS(≥3 字)+ LIKE(≤2 字)两分支、拼音命中路径、`type_filter` Some/None。

## 实现步骤

1. 补搜索路径测试(`storage_tests.rs`),`cargo test --lib` 确认绿。
2. 加 `item_cols` / `list_item_cols` 两个生成函数。
3. 逐个调用点替换为派生 SQL(按上表前缀/rank 映射)。
4. decoder 加契约注释。
5. 改 CLAUDE.md:把"12 处 SELECT 必须同时改"改写为"改 `item_cols`/`list_item_cols` + 对应 decoder"。

## 验收

- `cd rust && cargo test --lib` 全绿(含新补的搜索测试)。
- `xcodebuild -project Clipin.xcodeproj -scheme Clipin -configuration Debug -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test` 全绿(跨 target)。
- Codex 子 agent review。

## 风险

- `ci.` 前缀漏加 → JOIN 列歧义 → SQL 直接报错,测试必中,不会静默错。
- 收口后 SQL 字符串在空白/换行上可能与原文不同,但语义等价;测试绿即可,不要求字节级一致。
