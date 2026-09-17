# Clipboard Panel 设计（第三个原生面板：粘贴板历史）

日期：2026-09-17
状态：待用户评审

## 0. 产品版图

Lexi 定位趋向 tinycast + openclip 的联合体，原生面板家族固定为三个：

| Panel | 职责 | 现状 |
|---|---|---|
| **ActionPanel** | 选词工具栏 + 结果卡片（翻译/AI/笔记入口） | 已有（`SelectionToolbarHelper.swift`） |
| **LauncherPanel** | 双击 Shift 的文件夹/应用快速切换 | 已有（`LauncherPanel.swift`） |
| **ClipboardPanel** | 粘贴板历史：采集 → 搜索 → 回贴 | 本设计 |

用户确认：**后续会把 Notes 移入 ClipboardPanel**（作为其一个页签/分区）。本设计不改 Notes，但面板控制器结构按"可容纳多个内容分区"组织，为并入留缝。

## 1. 目标

全局快捷键（默认 **Alt+V**）唤起原生粘贴板历史面板：

- 采集：文本 / 图片 / Finder 文件引用，带来源 App 图标。
- 界面：hapigo 式布局（分类彩色圆点 chips 行、搜索框、多行预览列表、底部状态条），视觉语言与既有两面板一致（KeyablePanel 玻璃 + CardTheme + selectedFill 选中胶囊）。
- 回贴：Enter 把条目写回剪贴板并合成 ⌘V 粘贴进唤起前的应用，面板隐藏。

## 2. 非目标（v1 不做）

- 用户自定义分类（hapigo 的 git commit/密码 智能分类 + ⊕ 按钮）—— v2；chips 固定 5 类。
- 颜色识别 swatch（tinycast ColorValue 可后续移植）。
- per-app 采集禁用列表（tinycast `clipboardDisabledApps`）。
- 清空全部按钮（⌫ 逐行删除够用）。
- Notes 并入（后续独立迭代）。
- 主窗口管理页（Settings 仅一个快捷键下拉）。

## 3. 触发与快捷键

### 3.1 快捷键（复用 ShortcutMode 全套基建）

- 新模块 `src-tauri/src/clipboard.rs`（镜像 `launcher.rs`）：`CLIPBOARD_SHORTCUT` 静态量，默认 `"Alt+V"`（`KeyCombo{alt, kVK_V}`）；`set_clipboard_shortcut` 命令；`initialize` 从 sqlite `settings.clipboardShortcut` 读初值（复用 sqlite3 CLI 模式）。
- 组合键走 KeyDown：tap 中新增 arm `crate::clipboard::is_clipboard_hotkey(event)`（置于 launcher arm 之后）。
  **该 arm 是 tap 中第一个吞键路径：返回 `CallbackResult::Remove`**。原因：Option+V 在 macOS 输出 `√`，不吞会把死字符打进粘贴目标。其余 arm 一律不改（保持 `Keep`）。
- 双修饰键 preset（Alt+Alt 等）走 FlagsChanged：`handle_flags_changed` 末尾并行调 `crate::clipboard::handle_flags_changed`（launcher 旁，复用 `detect_double_press` + 打字防误触，`LAST_CLIPBOARD_PRESS` 独立静态量）。

### 3.2 开关即切换（toggle）

`/clipboard-show` 在 helper 端实现为 **toggle**：面板已可见则隐藏。热键连按不产生 reshow 闪烁，也不需要 Rust 侧维护可见状态。Esc/失焦隐藏照旧（postAction `clipboard-hidden`，Rust 仅记日志）。

### 3.3 设置 UI

`types.ts` `AppSettings.clipboardShortcut` + `defaults.ts`（默认 `"Alt+V"`）+ `SettingsPage` 在 launcher 快捷键行下方加 Select：Alt+V（默认）/ Cmd+Shift+V / Ctrl+Shift+V / Alt+Alt / Cmd+Cmd。`App.tsx` 启动同步追加 `set_clipboard_shortcut`。

## 4. 采集引擎（`native/ClipboardMonitor.swift`，tinycast 移植）

- **0.5s `Timer` 轮询** `NSPasteboard.general.changeCount`（tolerance 0.1），helper 启动即开始，无常开开关（面板即产品核心）。
- **自身写入跳过**：lexi/面板写入一律携带私有标记 `com.lexi.clipboard.internal`（空 Data），轮询器见标记即跳过。
- **敏感内容守卫**（无条件，先于一切分支）：pasteboard 含 `org.nspasteboard.ConcealedType` / `org.nspasteboard.TransientType` / `com.apple.is-sensitive` 任一 → 不采集。
- **来源归属**：pasteboard 不携带来源，取采集时刻 `NSWorkspace.shared.frontmostApplication` 的 bundle id（0.5s 窗口内切走的极小概率误归属，v1 接受）。图标按 bundle id 缓存 PNG 到 `icons/`（LaunchServices 定位 app URL → `NSWorkspace.icon(forFile:)` 渲染 36px@2x 一次）；未知来源回退通用文本字形。
- **分支顺序**（tinycast 不变量）：
  1. `fileURLs`：读每项 `public.file-url`（**先于 text**——Finder 把文件名放在 `.string` 旁）；拒绝 volatile roots（`/tmp/`、`/var/tmp/`、`/var/folders/`、`~/Library/Caches/`）；批上限 32；返回 nil 而非空数组让 text 分支接手。
  2. `.string` 文本：去空白后非空才收；上限 32,000 字符。
  3. `.png`/`.tiff` 图片：TIFF→PNG 重编码在 detached task（可 100ms+）；大图同样受 32KB 文本上限豁免（图片无文本上限）。
- **注入租约互斥**：lexi 翻译注入第 3 层（clipboard lease + ⌘V）期间轮询器必须挂起，否则译文被采成垃圾行。新增 TCP 端点 `POST /clipboard-suspend` / `POST /clipboard-resume`（body 携带租约前 changeCount；resume 时若 changeCount 未变则同步基线，变了说明有真实外来写入照常采）。`text_injection.rs` 租约写入前 post suspend、恢复后 post resume（两个 TCP 调用，失败仅日志）。
- **去重**：与当前第一条同 kind+同 content → 忽略（tinycast `addText` 语义）；不同 → `promote`（同 id delete+reinsert 单事务，blob 不动）置顶。
- 停止/恢复：helper 被 watchdog 重启即随进程重建（SQLite 状态在盘上）；无 fast-user-switch 观察者（v1 从简，tinycast 有）。

## 5. 存储（`native/ClipboardStore.swift`，Foundation+SQLite3 纯移植）

- 位置 `~/Library/Application Support/com.lexi.selection-helper/`：`clipboard.sqlite3` + `images/`（PNG blob）+ `icons/`（来源图标缓存）。helper 拥有，主程序 v1 不触碰。
- Schema（tinycast 原样）：

```sql
CREATE TABLE IF NOT EXISTS items(
  id TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL,          -- text | image | file
  text TEXT,                   -- 文本内容；file 时为绝对路径
  image_path TEXT,             -- 仅 image，指向 images/ 内自有文件
  created_at REAL NOT NULL,
  source_app TEXT,             -- 来源 bundle id，可空
  pinned_at REAL               -- 固定时间戳，非标记
);
CREATE INDEX items_created_at ON items(created_at);
CREATE INDEX items_pinned_at ON items(pinned_at) WHERE pinned_at IS NOT NULL;
CREATE VIRTUAL TABLE items_fts USING fts5(text, content='items', content_rowid='rowid', tokenize='trigram');
-- + ai/au/ad 三个 FTS 同步触发器
```

- **装载**：两条索引分支（全部 pinned + 最新 1000 条 unpinned），常驻窗口；文件条目引用原路径不拷贝，`image_path` 恒 nil（删除/剪枝永不触及非自有文件）。
- **搜索**：≥3 字符走 FTS5 trigram（`LIMIT 200`）；<3 字符或库打不开时在常驻窗口内存过滤。查询结果 memo 一层。
- **剪枝**：默认 90 天（unpinned），启动+采集时顺带执行；pinned 豁免。库打不开 → 删档重建（历史是采集物而非创作物）。
- **排序语义**：`items` 纯 recency；展示层 pinned 块（按固定时间）在上，其余 recency。unpin 重新按最新入列（delete+reinsert）。**回贴不提升 pinned**。

## 6. 面板（`native/ClipboardPanel.swift`）

### 6.1 结构与视觉（lexi 面板语言 + hapigo 布局）

- `ClipboardPanelController`（镜像 LauncherPanelController）：自持 `KeyablePanel`（borderless + nonactivating，floating level，canJoinAllSpaces），`makePanelBackground(cornerRadius: 14)` + 主题对比 scrim，`applyTheme(dark:)` 由 helper `applyTheme` 末尾同步调用。宽 520pt，定位同 launcher（鼠标屏水平居中、顶部 25%）。
- 垂直排布（FlippedView）：
  1. **搜索框**（同 launcher：26pt 高，无 focus ring，13pt，首响应者）。
  2. **chips 行**（hapigo 分类行）：`● 全部(灰) · 固定(粉) · 文本(蓝) · 链接(绿) · 文件(橙)`，8pt 色点 + 12pt 文字的胶囊按钮，选中 `selectedFill`、未选透明 hover `hoverFill`——与 launcher tab pill 同语法。互斥过滤（tinycast ClipboardFilter 语义：链接不算文本）。Tab 键循环切换。
  3. **列表**：NSTableView 变高行（`heightOfRow`），行内：20pt 来源图标 + 预览文本。文本条目 ≤3 行（13pt/17pt 行高，尾截断），短文本单行 32pt 行；文件条目首行文件名加粗 + 次行灰色路径；图片条目 28pt 缩略图（`images/` 降采样 NSImage）。Pinned 节头部行（launcher 同款 header 行）。选中 = `selectedFill` 圆角胶囊（非系统蓝）。
  4. **底部状态条**（hapigo）：24pt，顶部 hairline，左 `已选 {i} 项，总共 {n} 项`，右 `⌘P 固定 · ⌫ 删除 · ↩ 粘贴`（`tertiaryText`）。
- 高度自适应：min 200 / max 560（比 launcher 高 80pt，多行预览需要）。
- 空态：`emptyLabel`「暂无粘贴板历史 — 复制任意内容开始」。

### 6.2 键盘

搜索框常为 first responder，输入即过滤；`↑↓` 移动选中（跨 pinned/普通区连续，转入 table 的 responder 链模式同 launcher）；`Enter` 回贴并隐藏；`Esc` 隐藏（搜索框有文字先清空）；`Tab` 切 chips；`⌘P` 固定/解固定选中行（解固定后选中跟随到新位置）；`⌫` 删除选中行（含其自有图片 blob）；双击 = 回贴。

### 6.3 回贴（Paster，tinycast 契约）

`show()` 时记录 `previousApp = NSWorkspace.shared.frontmostApplication`。

Enter：
1. `store.promote` 跳过 pinned；写 pasteboard：`clearContents` → 按 kind 声明 flavors（text: `.string`；image: `.png`；file: `.fileURL` + `.string`(路径) —— 文件双 flavor，文本框收路径、Finder 收文件）+ `internal` 标记。
2. `previousApp.activate()` → 80ms → `CGEventSource(combinedSessionState)` 合成 V down/up，flags `.maskCommand`。
3. 面板 `orderOut` + postAction `clipboard-hidden`。
4. **不恢复原剪贴板**：被选条目成为当前剪贴板（剪贴板管理器标准语义，与 hapigo/Paste/Maccy 一致）；poller 因标记跳过，`store.promote(item)` 手动置顶。
5. 消失的文件：写失败 → 面板 HUD 文案提示（该行仍保留），不静默。

## 7. 进程间协议（复用 TCP）

Rust → helper：`POST /clipboard-show`（toggle）、`POST /clipboard-hide`、`POST /clipboard-suspend`（`{changeCount}`）、`POST /clipboard-resume`（`{changeCount}`）。
helper → Rust（既有 postAction 通道）：`clipboard-hidden`（Rust 仅日志）。
`handleRequestData` 增 4 条前缀分支；app delegate 增 `clipboardController` lazy 属性 + `applyTheme` 末尾通知。与 launcher/notes/card 互不感知，抢 key 后各面板按既有 resignKey 自理。

## 8. 模块边界（顶层隔离、底层复用）

### 新增（隔离层）

| 文件 | 内容 |
|---|---|
| `src-tauri/src/clipboard.rs` | 快捷键状态、`set_clipboard_shortcut`、`initialize`、`is_clipboard_hotkey`、`handle_flags_changed`、`show_clipboard`、suspend/resume 发送 |
| `src-tauri/native/ClipboardStore.swift` | Foundation+SQLite3 存储层（可独立编译） |
| `src-tauri/native/ClipboardMonitor.swift` | 轮询采集 + 敏感守卫 + suspend/resume 状态 |
| `src-tauri/native/ClipboardPanel.swift` | 面板 UI + Paster 回贴 |

### 既有文件最小接缝（每处 ≤ 数行）

| 文件 | 改动 |
|---|---|
| `src-tauri/src/lib.rs` | `mod clipboard;` + 注册命令 + setup 调 `clipboard::initialize` |
| `src-tauri/src/native_toolbar.rs` | KeyDown clipboard arm（`CallbackResult::Remove`）；`handle_flags_changed` 调 clipboard 检测 |
| `src-tauri/src/text_injection.rs` | 租约窗口前后 post suspend/resume |
| `src-tauri/native/SelectionToolbarHelper.swift` | `clipboardController` 属性、`handleRequestData` 4 分支、`applyTheme` 通知 |
| `src-tauri/build.rs` | swiftc 追加 3 个新 Swift 文件（+ rerun-if-changed） |
| `src/types.ts` / `src/lib/defaults.ts` / `src/pages/SettingsPage.tsx` / `src/App.tsx` | `clipboardShortcut` 设置项 + 同步 |

ActionPanel/LauncherPanel/翻译/选词/笔记/复习行为零改动。

## 9. 错误与边界

- **库打不开** → 删档重建（tinycast 论证：历史是采集物）。FTS 不可用 → 内存过滤兜底。
- **Alt+V 与 `√` 输入冲突**：tap 吞键解决；用户在需要的场合可在 Settings 换 preset。
- **Helper 重启**：轮询重启（基线 changeCount 重新取当前值，避免把重启间隙的外来写入整批误采——只采最新一条），面板重建，数据在盘上。
- **大文本**（>32K 字符）/ 大批量文件（>32）/ volatile root / 敏感标记：跳过或截断，规则见 §4。
- **链接分类**：展示层按前缀判定（`scheme://`、`mailto:`），不入库（kind 仍为 text）——tinycast 分类器即时派生不变量。
- **多屏**：以鼠标所在屏定位（同 launcher）。
- **与两面板同时可见**：互不感知；后抢 key 者胜，原面板 resignKey 自隐。

## 10. 验证（手动 smoke；仓库无 Swift/面板测试基建，Rust 单测覆盖可测纯函数）

1. `npm run tauri build`（helper 三新文件编译 + 签名通过）；`cargo test` 过（launcher 既有 double-press 测试不回归）。
2. 各 app 复制文本/截图/Finder 文件 → Alt+V → 条目按序出现、来源图标正确、长文本 ≤3 行预览、底部计数正确。
3. `√` 不落入粘贴目标（吞键生效）；快速 `Alt+H Alt+I` 类输入不误触（组合键无此路径，双修饰 preset 时验证）。
4. Enter → 内容粘贴进唤起前应用，面板隐藏，条目置顶；pinned 条目回贴不提升。
5. ⌘P 固定/解固定、⌫ 删除、chips 过滤、≥3 字符搜索命中历史深处条目。
6. 1Password/浏览器隐式复制（ConcealedType）不采集。
7. 触发一次翻译注入（走 clipboard lease）→ 历史无译文垃圾行（suspend/resume 生效）。
8. Alt+V 再按一次 → 面板关闭（toggle）。
9. 回归：双击 Ctrl popup、双击 Shift launcher、选词 toolbar、result card、Notes 面板行为不变。
