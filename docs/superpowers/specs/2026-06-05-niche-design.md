# Niche — 设计文档

> **状态**:设计已确认,待转实现计划
> **日期**:2026-06-05
> **暂存位置说明**:Niche 是独立的开源 app,最终拥有自己的 repo。当前仍在设计阶段、repo 未建,本设计稿暂存于 Clipin 仓库;进入实现、正式建立 Niche repo 时迁出。

---

## 1. 一句话定位

**Niche 是一款真·原生(macOS 26 Liquid Glass)、极简、且不阉割基础能力的开源文件快捷访问器。** 从 MacBook 刘海(无刘海时回退屏幕顶部)滑出一个悬浮窗,把用户绑定的几个常用文件夹"镜像"出来,随手取用、拖拽、预览,用完即走——像系统自带的一样。

命名:**Niche** /niːʃ/,与 *notch* 同源意象(凹槽 / 专属凹空间),刘海本质就是屏幕顶部的一个 niche;含义"专属小天地" = 常用文件夹的专属空间。

## 2. 目标用户与市场空白

- **目标用户**:会用 macOS 26、在意原生质感、上 GitHub 的进阶用户(开发者 / 设计师 / 重度文件操作者)。这类人恰恰需要完整能力(隐藏文件、完整文件操作),不需要"小白友好"的功能阉割。
- **市场空白**(调研结论):刘海赛道(NotchNook / NotchShelf / NotchDrop / BoringNotch / MewNotch / LookieLoo …)清一色做"**临时暂存 shelf + 媒体控制**"。**没有一个做"常用文件夹镜像 + 刘海原生交互"。** 而做"文件夹镜像"的 Folder Slice,UI 是上一代质感、非刘海触发。Niche 把 Folder Slice 的"文件夹镜像"模型搬到刘海原生交互 + Liquid Glass 质感上,填补这个空位。

## 3. 核心原则(贯穿所有取舍)

1. **原生正确性 > 功能数量**:「Finder 能做的,我们在自己范围内不阉割」。显示隐藏文件、完整文件操作语义都属于此——不是卖点,是底线。
2. **极简,守住主线**:只做"文件夹镜像快速访问"一件事。竞品的暂存盘(B 模型)、媒体控制、付费堆料一律不做。
3. **调用系统服务,不自研引擎**:文件操作、预览、压缩、分享全部走系统框架(FileManager / NSWorkspace / Drag&Drop / QuickLook / NSSharingService)。这与 Clipin "调系统 zip/Vision 不算破零依赖红线"同源。
4. **开源 + 不沙盒 + 自分发**:显示隐藏文件、任意路径访问要求不走 App Store 沙盒;GitHub Release 自分发。这是一致自洽的技术-商业组合。

## 4. MVP 范围

### 4.1 数据模型:纯文件夹镜像

- 绑定**多个**真实文件夹,顶部 tab 切换(不做单文件夹阉割版;多文件夹是核心体验)。
- 每个绑定文件夹通过 **security-scoped bookmark** 持久化授权(不沙盒也用 bookmark,保证重启后路径授权稳定 + 跨卷/外置盘可靠)。
- 用 **FSEvents** 监听绑定目录,磁盘内容变化实时同步到窗口(镜像语义:窗口显示的就是磁盘真实状态)。

> **关键区分**:这是"指向磁盘真实文件的入口",不是 Clipin 那种"拷进来归我管的快照"。数据生命周期完全不同——文件随时会被外部改/删/移,UI 必须容忍并实时反映。

### 4.2 触发与窗口呼出

- **位置优先级**:刘海热区优先 → 可选 顶部中央 / 左 / 右 / 菜单栏图标 → 全局快捷键兜底。
- **多屏**:在鼠标当前所在屏触发;该屏无刘海时自动回退顶部中央。用 `NSScreen.safeAreaInsets` / `auxiliaryTopLeftArea` 判断是否有 notch。
- **激活方式**:hover(带 intent 延迟防误触)+ 拖拽靠近自动展开(拖着文件接近刘海,窗口主动迎上来接住)。
- **触发逻辑必须区分"空手 hover"与"拖着文件 hover"**:后者用更快的 spring 迎上,因为用户在等它接住。

### 4.3 触发动画(苹果味的核心)

- 实现:引入开源 SwiftUI 库 **DynamicNotchKit**(MrKai77)快速达成,后续若需纯净化再替换(见 §7 依赖决策)。
- 动画细节:
  - **从刘海"长出来"而非"弹窗淡入"**:初始宽度=刘海宽度,向下 + 两侧 morph 到全宽,**圆角全程连续(continuous squircle)**,与刘海黑融为一体。
  - **弹性而非线性**:spring 带极轻回弹;收回时对称收回刘海再消失。
  - **内容交错淡入(staggered)**:面板骨架先到位,缩略图按行/列递延淡入 + 轻微上浮。
  - **hover 预备反馈**:鼠标进热区,刘海先有几像素"下沉/高光呼吸",停留够久才真正展开。
  - **拖拽态接管**:拖文件靠近时用更快 spring 迎上。
  - **尊重「减弱动态效果」(Reduce Motion)**:开启时降级为淡入。

### 4.4 浏览

- 网格视图 + 缩略图;缩略图 **后台 ImageIO 解码 + 缓存上限**(复用 Clipin 方案,禁止 row 渲染路径同步解码)。
- 排序:名称 / 修改日期 / 大小 / 类型。
- **显示隐藏文件开关**(原生正确性)。

### 4.5 文件操作(全系统 API,零自研)

| 操作 | 系统 API | 与 Finder 一致性 |
|---|---|---|
| 打开 / 默认 app 打开 | `NSWorkspace.open` | 完全一致 |
| 在 Finder 中显示 | `NSWorkspace.activateFileViewerSelecting` | 完全一致 |
| 删除到废纸篓(可⌘Z恢复) | `NSWorkspace.recycle`(带 Finder 同款音效+动画) | 完全一致 |
| 重命名 | 就地编辑 UI + `FileManager.moveItem` | 行为一致 |
| 复制 / 移动 | `FileManager.copyItem / moveItem` | 完全一致 |
| 剪切 / 拷贝 / 粘贴(⌘X/C/V) | `NSPasteboard` file URL + copyItem | 完全一致 |
| 拖入 / 拖出(移动vs复制语义、⌥⌘修饰、+角标) | AppKit Drag&Drop + `NSFilePromiseProvider`(延迟生成) | 系统自动判同卷移动/跨卷复制 |
| Quick Look 预览 | `QLPreviewPanel` | 完全一致 |
| 新建文件夹 | `FileManager.createDirectory` | 一致 |
| 分享 | `NSSharingServicePicker` | 系统分享菜单本体 |
| 压缩 | 调系统 `ditto` / Archive Utility | 结果一致 |
| Finder 标签(彩色标记) | URL resource `.tagNamesKey` | 读写系统标签 |

**系统硬边界(诚实记录,非偷懒)**:
1. **右键上下文菜单做不到"= Finder 那个菜单本体"**——Finder 右键菜单是其私有的,任何第三方都无法原样调出。Niche 用 `NSMenu` 自拼一个覆盖 ~95% 常用项的菜单,每项仍调上表系统 API。NotchNook / Yoink / Path Finder 均如此。
2. **"显示简介(Get Info)"无公开 API**——只能做近似面板或不做(MVP 不做)。

**拖拽安全红线**(沿用 Clipin 经验):拖拽默认按 Finder 语义(同卷移动 / 跨卷复制),⌥ 强制复制、⌘ 强制移动,光标显示 +/箭头角标。任何写操作前校验目标可写,删除一律走废纸篓(可恢复),**禁止静默移动或真删用户文件**。

### 4.6 窗口行为(可切换状态机)

- **Resize**:拖窗口边/角调大小;**记忆尺寸 + 位置**。
- **Pin(钉住)**:把"用完即走的瞬态面板"切换成"常驻浮窗"——不再失焦自动隐藏、置顶(always-on-top)、可拖离刘海放到任意位置(detach,类似系统画中画)。
- **未 pin 时**:失焦自动隐藏;⌘W / Esc 收回。

> **关键设计:Pin 是两种窗口模式的切换,不是布尔开关。** 未 pin = 借刘海的瞬态 NSPanel(nonactivating、失焦即隐、不进 Mission Control);pin = 普通可激活、可拖动、always-on-top 浮窗。两者窗口层级 / collectionBehavior / 焦点策略完全不同。**从第一行代码就把"窗口模式"做成可切换状态机,不能先写死 launcher 再改**(Clipin 在"连续粘贴夺回 key window"上踩过同类瞬态/常驻切换的坑)。

### 4.7 键盘导航(差异化优势)

- ↑↓ 选择 / Space Quick Look 预览 / Return 打开 / ⌘↓ 进子目录 / ⌘↑ 回上级。
- 这是 Clipin 看家本领,竞品几乎纯鼠标,这里直接拉开差距。

## 5. 明确不做(v2+,守住极简)

标签系统、智能文件夹、多维筛选(时间/类型)、抠图 / OCR / 翻译 / 格式转换 / srt→fcpxml / 视频压缩(Folder Slice 付费料整组)、AirDrop 拖拽区、Share Sheet 深度集成、列表视图 / 多缩略图尺寸、窗口透明度、auto-unpin 定时器、多浮窗、鼠标穿透、Get Info 面板。

## 6. 架构与代码复用

复用 Clipin 已造好的基础设施,**抽成可共享的通用层**(而非 fork 整个 Clipin,避免把 Clipin 的产品差异化资产以源码公开):

| 复用自 Clipin | 用途 |
|---|---|
| NSPanel 呼出骨架 + 全局快捷键 + 非 floating 窗口层级处理 | 窗口呼出 / 触发 |
| 缩略图后台 ImageIO 解码 + 缓存上限 | 网格缩略图 |
| Quick Look resolver + session 三层架构 | Space 预览 |
| Rust 存储骨架(可选) | 绑定文件夹配置 / 设置持久化(也可纯 Swift UserDefaults,MVP 数据量小) |
| ClipinChrome 设计体系思想(禁卡片套卡片、底栏各按钮自承材质、edge 单旋钮派生间距) | Liquid Glass 原生质感 |

**新建模块(Clipin 没有、需新写)**:
1. **刘海检测 + 触发热区 + 回退**(`NSScreen` notch 几何计算)。
2. **DynamicNotchKit 接入 + 展开/收回动画编排**。
3. **文件夹镜像数据源**(security-scoped bookmark + FSEvents)。
4. **Pin 窗口模式状态机**(瞬态 NSPanel ↔ 常驻浮窗)。
5. **文件操作命令层**(封装 §4.5 系统 API + 拖拽语义 + 自拼右键 NSMenu)。

**打包**:独立 app、不沙盒、GitHub Release 自分发(非 MAS)。Apple Silicon 优先(沿用 Clipin arm64 决策)。

## 7. 关键技术决策

- **依赖策略**:**Niche 不继承 Clipin 的"零第三方 SPM 依赖"红线。** 作为开源 app,引入高质量同生态库(DynamicNotchKit)以快速达成动画体验是合理取舍;Clipin 的洁癖源于其特定约束,不适用于此。MVP 先引库验证体验,后续视情况决定是否纯净化替换。
- **不沙盒**:换取隐藏文件 + 任意路径访问;代价是不能上 MAS(开源自分发本不靠 MAS)。
- **bookmark + FSEvents**:不沙盒也用 security-scoped bookmark 持久化授权,FSEvents 做镜像同步。

## 8. 风险与开放问题

1. **DynamicNotchKit 的可定制度**是否足够实现 §4.3 全部动画细节(尤其 hover 预备反馈、拖拽态接管)——实现首阶段需验证,不满足则部分自研。
2. **FSEvents 在大目录(数千文件)下的刷新性能** + 缩略图缓存压力——需压测,必要时分页/虚拟化。
3. **right-click 自拼菜单的项覆盖度**——首版定一个常用项清单(打开/打开方式/Reveal/重命名/拷贝/移动到/复制路径/压缩/标签/删除/分享),后续按反馈增补。
4. **product 名 Niche 商标/域名**可用性——上线前最终核验(初步搜索无同名 mac app)。

## 9. 里程碑建议(粗粒度,细化留给实现计划)

1. **M1 骨架**:刘海触发热区 + DynamicNotchKit 展开动画 + 单文件夹只读网格。
2. **M2 镜像与浏览**:多文件夹 tab + bookmark + FSEvents + 排序 + 隐藏文件 + Quick Look + 键盘导航。
3. **M3 文件操作**:全套系统 API 文件操作 + 拖入拖出语义 + 自拼右键菜单。
4. **M4 窗口行为**:Resize + 记忆 + Pin 状态机 + detach。
5. **M5 打磨**:Liquid Glass 质感、动画细节、Reduce Motion、多屏、设置页、开源发布准备。
