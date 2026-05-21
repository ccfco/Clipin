# Clipin 粘贴项 — Rename(改显示名) + Edit Content(改真实内容)

- 日期:2026-05-21
- 状态:方向已由用户多轮澄清锁定,本 spec 待用户复核后转 writing-plans
- 基线:`main`,当前 schema 版本 v9

## 背景与问题

Clipin 的剪贴板历史里,一条记录在主列表左栏只显示一行"预览名"——目前这个预览名是 SQL 层 `COALESCE(NULLIF(ocr_text,''),content)` 兜底出来的,本质就是内容本身的截断。

这带来两个真实痛点:

1. **长内容/无语义内容难以辨认**。一段 4KB 的中文、一个 `ghp_` 开头的 token、一串 Base64、一个裸 URL,在列表里都只能看到机器截断的前几十个字符。用户记不住"哪一条是 GitHub 的密钥""哪一条是上周给客户的话术",每次都要逐条点开 preview 确认。
2. **历史条目无法修订**。剪贴板内容一旦入库就是死的。用户复制了一段文字,发现里面有个错字、或想删掉一段冗余,只能重新去源头改好再复制一遍——历史记录帮不上忙。

对应两个独立功能:

- **Rename**——给条目挂一个用户可读的**显示名(别名)**,原始内容不变,只改列表/预览上"看到的名字"。解决痛点 1。
- **Edit Content**——直接编辑条目的**真实内容**,改完后粘贴出去就是新内容。解决痛点 2。

两者共用同一根数据骨架(`clip_items` 增加一列、FTS5 重建一次),但交互路径完全不同,本 spec 把它们设计成两个可独立实现、独立测试的单元。

## 目标

- 用户能给任意类型(text/url/image/file)的条目起一个别名;别名为空时列表回退到内容兜底预览。
- 用户能编辑 text/url 条目的真实内容;改完保存后,该条目后续粘贴、搜索、预览全部基于新内容。
- 别名与内容都纳入搜索(FTS5 + 拼音),与现有 `content`/`ocr_text` 同构。
- 别名纳入导出/导入备份。
- 两个功能都遵循 Clipin 既有的键盘优先心智:经 ⌘K 动作面板触发,编辑期间键盘上下文正确隔离。

## 非目标

- 不做"标签/多对多 tag"系统——别名是单条目的单一字符串属性。
- 不做别名的批量管理界面、别名历史、别名模板。
- Edit Content 不对 image/file 类型开放(它们的 `content` 是路径,编辑路径会破坏条目)。
- 不为 Rename/Edit Content 注册全局热键——只在 ⌘K 动作面板内提供命令与面板内快捷键。

## 功能规格

### Rename — 改显示名/别名

| 维度 | 规格 |
|---|---|
| 语义 | 给条目挂一个用户可读别名(`alias`);原始 `content` 永不改变 |
| 入口 | ⌘K 动作面板 → `Rename` 命令(面板内快捷键 `⇧⌘E`) |
| 编辑 UI | 访达式 inline:选中行的名字文字**原地**切换为 `TextField` |
| 预填 | 进入编辑时预填该行**当前显示的名字**(已有别名则是别名,否则是兜底预览名),文字默认全选 |
| 提交 | `Return` 提交 |
| 取消 | `Esc` 取消,恢复原显示 |
| 清空语义 | 提交空字符串 = 删除别名(写 `NULL`),列表回退到内容兜底预览 |
| 列表显示 | 有别名只显示别名;无别名显示内容兜底预览 |
| 视觉信号 | 有别名的行加一个轻量信号(行首小圆点),与"无别名兜底"行可区分 |
| 适用类型 | text / url / image / file 全部 |
| 视图范围 | pinned 视图与普通浏览视图都生效(别名是条目自身属性,不随 browseMode 变化) |
| 搜索 | 别名进入 FTS5,与 `content` 等权;中文别名同样走拼音 trigram |
| 备份 | 别名进入 export/import |

### Edit Content — 改真实内容

| 维度 | 规格 |
|---|---|
| 语义 | 编辑条目真实 `content`;保存后后续粘贴/搜索/预览全部基于新内容 |
| 入口 | ⌘K 动作面板 → `Edit Content` 命令(面板内快捷键 `⌘E`);选中项为 image/file 时该命令不出现 |
| 编辑 UI | 右侧 preview 区切换为可编辑 `TextEditor`(主面板保持双栏,左侧列表仍可见) |
| 适用类型 | 仅 text / url |
| 提交 | `Save`(`⌘↵`)提交 |
| 取消 | `Esc` 放弃编辑 |
| 类型重判定 | 保存时根据新内容重新判定类型(text ↔ url 自动切换) |
| 时间位置 | **不**浮到列表最近——编辑不是复制也不是粘贴,不打乱时间轴 |
| 连带失效 | 见下文"数据完整性规则" |

## 设计

### 单元 1 — DB migration v10(`rust/src/storage.rs`)

新增 `migrate_to_v10`,追加在 `migrate_to_v9` 之后,老 migration 全部冻结。

v10 做两件事:

1. `ALTER TABLE clip_items ADD COLUMN alias TEXT`(可空,默认 `NULL`)。
2. 重建 FTS5:把 `alias` 加为可搜索列。FTS 重建沿用既有套路——`DROP` 旧 `clip_fts` 与三个触发器 → 以新列集 `CREATE` → `INSERT ... SELECT` 重灌 → 重建三个触发器。

新的 `clip_items_au` UPDATE 触发器在 v8 列集基础上追加 `alias`:

```
AFTER UPDATE OF content, source_name, ocr_text, alias, pinyin_flat, pinyin_initials
```

`clip_items_ai`(INSERT)/`clip_items_ad`(DELETE)触发器同步把 `alias` 写入/删除出 FTS。

**回填**:v10 不需要回填拼音。老数据 `alias` 全为 `NULL`,`content` 未变,既有 `pinyin_flat`/`pinyin_initials` 仍然有效。因此 v10 是"ALTER + FTS 重建"两步,不需要 v5 那种独立的 Rust 回填阶段;但 FTS 重建本身仍需独立于 ALTER 之后执行(单条 `execute_batch` 内顺序即可,无需跨锁)。

### 单元 2 — Rust 写入接口:`set_alias` / `update_content`(`lib.rs` + `storage.rs`)

两个新 UniFFI 导出方法。

**`set_alias(id: String, alias: Option<String>)`**
- `alias` 为 `Some(非空)` → 写入别名;`None` 或 `Some("")` → 写 `NULL`(空字符串归一化为 `NULL`)。
- 写别名后**同步重算该条拼音**:`compute_pinyin` 的入参从 `content` 改为 `content + " " + alias`(别名为空则等于只算 content),`UPDATE` 写回 `pinyin_flat`/`pinyin_initials`。
  - 原因:`backfill_pinyin` 只处理 `pinyin_flat=''` 的条目,而已入库条目的 `pinyin_flat` 通常非空,backfill 不会重算它。别名的拼音必须由 `set_alias` 自己负责写入,否则中文别名搜不到。
- `alias`、`pinyin_flat`、`pinyin_initials` 都在 v10 触发器的 `UPDATE OF` 列集内,FTS 自动同步。

**`update_content(id: String, new_content: String, new_type: ClipType)`**
- 调用方(Swift)负责依据新内容判定 `new_type` 并传入。
- Rust 端在一个事务内:重算 `content_hash`(`Sha256(type:content)`,type 变化时 hash 自然变化)、重算 `char_count`/`word_count`、重算 `pinyin`(`content + alias`)、`UPDATE` 写回 `content`/`clip_type`/`content_hash`/`char_count`/`word_count`/`pinyin_flat`/`pinyin_initials`。
- 不触碰 `created_at`/`copy_count`/`paste_count`/`is_pinned`/`source_app`/`source_name`——这些是该条目的身份与使用信号,编辑内容不重置它们。
- **不套用去重**:即使新 `content_hash` 与库中另一条目相同,也不合并、不报错。去重只属于"剪贴板监控自动入库"路径;用户主动编辑产生的重复是用户意图,保留为两条。
- 清空该条目的 `clip_representations` 副表记录(理由见"数据完整性规则")。

### 单元 3 — Rust 读取/搜索/备份接入 alias(`storage.rs`)

- **列表查询**:`get_list_items` / `get_pinned_list_items` / `get_unpinned_list_items` / `search_list_items` 的 SQL 投影增加 `alias` 列;`ClipListItem` 的显示名优先级改为 `COALESCE(NULLIF(alias,''), NULLIF(ocr_text,''), content)` 的截断。`ClipListItem` 额外携带 `alias: Option<String>`,供 Swift 端判定"是否画视觉信号"。
- **完整记录**:`get_item` 返回的 `ClipItem` 增加 `alias` 字段。
- **搜索**:FTS 路径中 `alias` 已是 FTS 列,BM25 自动覆盖——别名是短字段,匹配权重天然高于埋在长 `content` 里的同词,符合直觉。LIKE 回退路径(≤2 字查询)的 `WHERE` 增加 `OR alias LIKE ?`,并复用既有的 LIKE 元字符转义。排序语义不变(见 CLAUDE.md "搜索候选必须在 SQL 层先排序再 LIMIT")。
- **导出**:`export_archive_snapshot` 返回的 `ArchiveSnapshotItem` 增加 `alias`。
- **导入**:`import_item_if_missing` 增加 `alias` 入参。语义对齐既有的 `paste_count` 处理——同 hash 重复条目默认跳过、保留现有 `alias`;但当**现有条目 alias 为空、备份里 alias 非空**时,补上别名并计为 imported。`import_item`(测试用)同步加 `alias` 入参。

### 单元 4 — Swift 数据模型(`Clipin/Generated/` 自动生成 + 消费方)

`ClipItem`、`ClipListItem`、`ArchiveSnapshotItem` 的 `alias` 字段由 UniFFI 重新生成绑定后自动出现。需要手动跟进的消费方:

- `ClipListItem` 的使用处:列表行渲染读 `alias` 决定显示名与视觉信号。
- 归档导入/导出代码路径(`ArchiveService`):序列化/反序列化 JSON 时带上 `alias` 字段。

### 单元 5 — Rename inline 编辑(`ClipboardViewModel` + `ClipListRow`)

**ViewModel 状态**
- 新增 `renamingItemID: String?`——非 nil 表示该 id 的行正处于 inline 编辑态。
- `beginRenaming(_ id:)`:设置 `renamingItemID`;若动作面板开着则先关闭。
- `commitRename(_ id:, alias:)`:空白归一化后,后台调用 `core.set_alias`;成功后刷新该行;清空 `renamingItemID`;经 `launcherNotice` 给一句轻量回声。
- `cancelRename()`:清空 `renamingItemID`,不写库。

**ClipListRow 渲染**
- 标题区:`if viewModel.renamingItemID == item.id` → 渲染 `TextField`,否则渲染原 `Text`。
- `TextField` 用 SwiftUI 原生 `TextField` + `@FocusState`;`onSubmit` 提交,`onExitCommand`(或 Esc 处理)取消。`onSubmit` 而非按键监听,避免 IME 组词回车被吞(见 CLAUDE.md IME 相关决策)。
- 进入编辑态时 `TextField` 抢焦点并全选预填文字。
- 列表行 `.id(item.id)` 保证 LazyVStack 滚动重建时复用同一 `TextField` 实例;`renamingItemID` 由 ViewModel 持有,不随 row 重建丢失。
- 视觉信号:`item.alias` 非空时,行首画一个轻量小圆点(尺寸/颜色复用现有 chrome token,不新造皮肤)。

### 单元 6 — Edit Content 编辑态(`ClipboardViewModel` + `PreviewPane`)

**ViewModel 状态**
- 新增 `editingContentItemID: String?` 与编辑草稿 `editingContentDraft: String`。
- `beginEditContent(_ id:)`:仅当选中项类型为 text/url 时可进入;载入完整 `content` 到草稿;若动作面板开着则先关闭。
- `commitEditContent()`:依据草稿内容判定新类型(复用 `ClipboardMonitor` 既有的 URL/类型判定逻辑,不另造一套),后台调用 `core.update_content`;成功后刷新该条目与 preview;清空编辑态;`launcherNotice` 回声。
- `cancelEditContent()`:丢弃草稿,清空编辑态。

**PreviewPane 渲染**
- `editingContentItemID == 当前选中 id` 时,preview 的内容 stage 替换为可编辑 `TextEditor`(绑定 `editingContentDraft`),metadata block 在编辑态隐藏,stage 高度全给编辑器;底部提供 `Save`/`Cancel` 按钮(`Save` 标 `⌘↵`)。
- 非编辑态保持现状(只读 preview)。

### 单元 7 — 动作面板两个命令(`ActionPalette` + `PaletteAction`)

- 新增两个 `PaletteAction`:`.rename`(`⇧⌘E`)、`.editContent`(`⌘E`),都携带结构化 `PaletteActionShortcut`(见 CLAUDE.md "动作面板里展示的快捷键必须是真快捷键")。
- 两者属于"依赖选中项的条目动作":无选中项时不出现。
- `.editContent` 额外条件:选中项类型为 text/url 才出现(image/file 选中时只出现 `.rename`)。
- 选中执行:`.rename` → `viewModel.beginRenaming(selectedID)`;`.editContent` → `viewModel.beginEditContent(selectedID)`。两者执行前都关闭面板。

### 单元 8 — 键盘上下文路由(`AppDelegate`)

Clipin 的本地键盘监视器按"当前窗口上下文"分发导航键。本设计新增两个上下文:

- `renamingItemID != nil`:inline 改名进行中。`↑↓` / `Space` / `⌘1-9` / `Tab` / `Shift-Tab` 全部交还给 `TextField`(不被 key monitor 拦截);`Return`/`Esc` 由 `TextField` 自身的 `onSubmit`/退出处理消化。
- `editingContentItemID != nil`:Edit Content 进行中。`↑↓` / `Space` / `⌘1-9` / `Tab` 交还给 `TextEditor`;`⌘↵` 提交、`Esc` 取消。

两个上下文都优先于主面板列表导航判定,避免编辑期间误触发列表上下移动或粘贴。`Esc` 在这两个上下文里只做"取消编辑",不触发既有的"先回退搜索/筛选、再关面板"分层逻辑。

### 单元 9 — 本地化文案(`Localizable.strings`)

新增 key:`Rename`、`Edit Content`、`Save`、改名/编辑成功与失败的 `launcherNotice` 文案。动态提示统一走 `NSLocalizedString + String(format:)`(见 CLAUDE.md 本地化决策)。

## 数据完整性规则

`content` 改变会让若干派生数据失效,必须在 `update_content` 这一次操作内一并处理,不能留脏数据:

| 派生数据 | 处理 |
|---|---|
| `content_hash` | 重算(`Sha256(type:content)`);type 变化也会反映进 hash |
| `char_count` / `word_count` | 重算 |
| `pinyin_flat` / `pinyin_initials` | 重算(入参 `content + alias`) |
| FTS5 索引 | v10 触发器自动同步,无需手动 |
| `clip_representations`(HTML/RTF/RTFD 副表) | 清空该条目的副表记录——plain text 已改,旧的富文本表示与新内容不一致,保留会导致粘贴出"看不见的旧富文本" |
| URL 元数据缓存(favicon / og:title) | 编辑后失效该条目的 favicon/标题缓存,下次预览重新抓取——内容变了,旧的抓取结果过期 |
| 去重 | 不套用——见单元 2 |

别名相关:`set_alias` 只影响 `alias` 与该条目拼音两项,不触碰其余任何字段。

## 风险与坑

1. **migration v10 的 FTS 重建**:必须先 `ALTER` 再重建 FTS,且 `DROP`/`CREATE`/`INSERT SELECT`/重建触发器顺序不能错。沿用 v3→v4(ocr_text 加列重建 FTS)的成熟套路,这次不涉及跨锁回填,风险低于 v5。
2. **LazyVStack 重建吞掉 inline TextField**:必须靠 `renamingItemID` 存活在 ViewModel + 行 `.id(item.id)` 稳定。若仅用 row 内部 `@State` 标记编辑态,滚动重建会丢失编辑中的输入。
3. **IME 组词回车被吞**:Rename 的 `TextField` 提交走 `onSubmit`,不在 key monitor 层拦 `Return`;否则中文别名的拼音选字回车会失效。
4. **type 重判定的连锁渲染**:text 编辑成 url 后,列表行图标、preview 渲染分支、favicon 抓取都要跟着新 type 走。Edit Content 提交后必须完整刷新该条目,不能只刷新 content 字段。
5. **动作面板命令的动态可见性**:`.editContent` 对 image/file 必须隐藏而不是禁用置灰——保持面板"列出来的都能执行"的心智(见 CLAUDE.md 动作面板决策)。
6. **键盘上下文优先级**:两个新上下文必须插在主面板列表导航判定之前,否则编辑期间方向键会同时移动列表选中项。

## 测试策略

**Rust 单元测试(`cargo test --lib`)**
- `set_alias` 写入/清空(空字符串归一化为 NULL)。
- 设置中文别名后,`search` / `search_list_items` 能用别名原文、拼音全拼、拼音首字母命中。
- 设置别名后 `ClipListItem` 的显示名优先 alias;清空别名后回退兜底。
- `update_content`:content/type/hash/char_count/pinyin 全部更新;`created_at`/`copy_count`/`paste_count`/`is_pinned` 不变;副表 representations 被清空。
- `update_content` 产生与他条目相同 hash 时不去重、不报错,库中仍是两条。
- export/import 往返保留 alias;同 hash 重复条目"现有 alias 空、备份非空"时补全并计为 imported。
- migration:v9 库升到 v10 后 schema 正确、老数据可读、FTS 含 alias 列;migration 幂等。

**手动验收(UI)**
- ⌘K → Rename:inline 编辑、全选预填、Return 提交、Esc 取消、空字符串删除别名;改名后列表立即反映、视觉信号出现。
- 改名对 text/url/image/file 四类条目都可用;pinned 视图与普通视图都可用。
- ⌘K → Edit Content:对 text/url 出现、对 image/file 不出现;preview 切编辑态、Save/Cancel、type 自动重判;编辑 url 后 favicon 重新抓取。
- 编辑期间键盘隔离:inline 改名与 Edit Content 进行中,方向键不移动列表选中项。
