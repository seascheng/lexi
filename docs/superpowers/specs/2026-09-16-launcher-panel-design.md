# Launcher Panel 设计（双击 Shift 唤起的项目/应用快速切换面板）

日期：2026-09-16
状态：待用户评审

## 1. 目标

Lexi 新增一个独立子系统：**双击 Shift 全局唤起的原生面板**，两个页签：

1. **文件夹页**：显示所有带 Finder 标签（彩色标签）的文件夹（按标签分组），以及「最近通过 Lexi 打开」的文件夹；Enter = Finder 打开，行内按钮 = 编辑器 / 终端打开。
2. **应用页**：显示当前运行中的常规 App（带图标），点击/Enter 即时切入。

架构约束（用户明确要求）：**顶层隔离、底层复用** —— launcher 是独立模块，不侵入现有翻译/选词/笔记/复习链路；只复用既有底层设施（事件 tap、TCP 传输、面板基建、主题系统）。

## 2. 非目标（一期不做）

- 实时解析 Stickies/Apple Notes（用户确认「标签」指 Finder 标签，已无此需求）
- 系统级 Finder「最近使用」列表（`.sfl` 解析），仅记录经 Lexi 打开的历史
- 文件夹行内管理（重命名/删除标签）——标签管理回归 Finder 本职
- Launcher 内容的主窗口管理页（Settings 仅一个快捷键下拉）
- 搜索文件内容 / 通用 Spotlight 替代

## 3. 触发与快捷键

### 3.1 检测（复用现有 CGEventTap）

- `ShortcutMode::DoubleCtrl` 泛化为 `DoubleModifier { key_code: u16 }`，`parse` 接受 `"Ctrl+Ctrl"` / `"Shift+Shift"` / `"Alt+Alt"`；popup 现有行为不变（`"Ctrl+Ctrl"` → `DoubleModifier(ANSI_Control)`）。
- Launcher 快捷键独立状态：`launcher.rs` 持有 `LAUNCHER_SHORTCUT`，默认 `DoubleModifier(ANSI_Shift)`。
- `handle_flags_changed`（tap 回调，底层）为两个用途分别跑双击检测：popup（若为 double 模式）与 launcher。触发 launcher 时调用 `crate::launcher::on_hotkey(app)` —— tap 对 launcher 的全部了解仅此一个函数。

### 3.2 双击 Shift 的防误触（与双击 Ctrl 的关键差异）

Shift 是大写输入键，连续 `Shift+字母 Shift+字母`（快速打大写）会在 300ms 内出现两次 Shift 按下。**规则：两次 Shift 按下之间若发生任何非修饰键 KeyDown，重置计时**（tap 在 KeyDown 分支记录 `LAST_NONMOD_KEYDOWN: Option<Instant>`；检测时要求区间内无此记录）。双击 Ctrl 路径同步获得该保护（行为增强，无回归风险）。

### 3.3 快捷键配置（复用现有设置链路）

- 新命令 `set_launcher_shortcut(String)`（`launcher.rs`，注册进 `lib.rs`）。
- 启动时 `initialize_launcher_shortcut` 读 sqlite `settings.launcherShortcut`（复用 `read_popup_shortcut_from_sqlite` 的 sqlite3 CLI 模式）。
- 前端：`types.ts` `AppSettings` + `defaults.ts`（默认 `"Shift+Shift"`）+ `SettingsPage` Popup 卡片内新增一行「Show launcher shortcut」。**用 Select 下拉**（双击 Shift / 双击 Option / 双击 Cmd / Cmd+Shift+L 等 preset），不用 `ShortcutRecorder`（其无法录制裸修饰键双击；泛化后的 parse 为将来扩展留口）。`App.tsx` 启动同步处（`set_popup_shortcut` 旁）追加 `set_launcher_shortcut`。

## 4. 面板（Swift 原生，新文件 `native/LauncherPanel.swift`）

### 4.1 结构

- `final class LauncherPanelController: NSObject, NSWindowDelegate`，自持一个 `KeyablePanel`（borderless，`makeKeyAndOrderFront` 接管键盘 —— 与 result card 同模式）。
- 尺寸：宽 520pt；高自适应（max ~480pt），列表区滚动。位置：鼠标所在屏幕水平居中，顶部约 25% 处（Spotlight 位）。
- 顶部 `NSSearchField` 过滤当前页；其下两枚 tab pill（复用 result card 的 pill 视觉语言）；主体 `NSTableView`（自绘行，模式同 notes 列表）。
- 主题：沿用 `/theme` 推送；`applyTheme` 末尾通知 `launcherController.applyTheme(_:)`。CardTheme 的 dark/light 派生色全部复用。
- 显示/隐藏：`show()` 时 `makeKeyAndOrderFront` + `makeFirstResponder(searchField)`；Esc（`cancelOperation:`）或 `windowDidResignKey` → `orderOut` 并 `postAction("launcher-hidden")`。

### 4.2 文件夹页数据

- **标签文件夹**：`NSMetadataQuery`，predicate `kMDItemUserTags == '*'`，scope `~`；客户端过滤 `isDirectory`，按首个 tag 名分组、组内按名称排序。tag 颜色用现有确定性 `tagColor(for:)` 哈希色（与笔记页同语言）。查询在 show 时启动（结果 >5s 视为陈旧则重查），`NSMetadataQueryDidFinishGathering`/`DidUpdate` 节流刷新；面板隐藏时 stop。
- **最近打开**：helper UserDefaults（`launcher.recents`：`[{path, count, lastAt}]`，容量 10，打开动作时更新并去重）——纯 launcher 状态不进主库。显示在标签组下方「Recent」一节。
- 行内容：tag 色点 + 文件夹名 + 父目录灰字 + 右侧两个 `HoverIconButton`（编辑器 / 终端，lucide 图标 `code` / `terminal`，markup 表已含）。

### 4.3 应用页数据

- `NSWorkspace.shared.runningApplications` 过滤 `activationPolicy == .regular` 且非自身；frontmost 置顶，其余按名称。行内容：App 图标（`NSRunningApplication.icon`）+ 本地化名。每次 show / 切到此页时重查。

### 4.4 打开动作

- **Finder**（Enter/双击）：`NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)`。
- **编辑器按钮**：按序探测 `com.microsoft.VSCode` → `dev.zed.Zed` → `com.sublimetext.4`（`NSWorkspace.urlForApplication(withBundleIdentifier:)`），命中即 `open(_:withApplicationAt:)`；全未安装则按钮隐藏。
- **终端按钮**：`open -a Terminal <path>`（Terminal bundle id `com.apple.Terminal`）。
- **App 行**：`application.activate()`，面板隐藏。
- 所有动作完成后 `orderOut`。

### 4.5 键盘

searchField 为 first responder：输入即过滤；`↑↓` 移动选中（转入 table，NotesTable 的 responder-chain 模式）；`Enter` 执行默认动作；`Tab` 在两页间切换；`Esc` 关闭（搜索框有文字时先清空，同 notes 搜索行为）。

## 5. 进程间协议（复用 TCP，新增两个端点）

Rust `launcher.rs` → helper（`post_to_helper`）：

- `POST /launcher-show`（body `{}`）：helper 端 `LauncherPanelController.show()`。
- `POST /launcher-hide`（body `{}`）：`orderOut`（供将来主窗口/脚本调用）。

helper → Rust（既有 `postAction` action 通道）：`launcher-hidden`（Rust 端仅记日志，无状态需清）。`handleRequestData` 增加两条前缀分支转发给 `launcherController` —— 这是 helper 侧唯一的既有文件改动点之一。

## 6. 模块边界（顶层隔离、底层复用 的落地清单）

### 新增（隔离层）

| 文件 | 内容 |
|---|---|
| `src-tauri/src/launcher.rs` | 快捷键状态、`set_launcher_shortcut`、`on_hotkey`、`initialize_launcher_shortcut`、`/launcher-show|hide` 发送、theme 无关 |
| `src-tauri/native/LauncherPanel.swift` | `LauncherPanelController` 全部 UI/数据/动作（~600 行） |
| `docs/superpowers/specs/2026-09-16-launcher-panel-design.md` | 本文档 |

### 复用（底层，Swift fileprivate → internal 提升）

`KeyablePanel`、`makePanelBackground`、`CardTheme`、`lucideImage` / `lucideMarkup` / `hexString`、`tagColor`、`FileLog`、`HoverIconButton`（若访问级别需要）。语义不变，仅去掉 `private`。

### 既有文件的最小接缝（每处 ≤ 数行）

| 文件 | 改动 |
|---|---|
| `src-tauri/src/lib.rs` | `mod launcher;` + 注册 `set_launcher_shortcut` |
| `src-tauri/src/native_toolbar.rs` | `ShortcutMode::DoubleCtrl → DoubleModifier` 泛化；`handle_flags_changed` 双用途检测 + 调 `launcher::on_hotkey`；KeyDown 分支记 `LAST_NONMOD_KEYDOWN` |
| `src-tauri/native/SelectionToolbarHelper.swift` | `handleRequestData` 两条 launcher 分支；`applyTheme` 通知 launcher；app delegate 持一个 `launcherController` 属性 |
| `src-tauri/build.rs` | swiftc 参数追加 `native/LauncherPanel.swift`（+ rerun-if-changed） |
| `src/types.ts` / `src/lib/defaults.ts` / `src/pages/SettingsPage.tsx` / `src/App.tsx` | `launcherShortcut` 设置项 + 同步 |

翻译/选词/笔记/复习/AI 卡片的任何行为零改动。

## 7. 错误与边界

- **Spotlight 索引关闭/外置卷**：NSMetadataQuery 可能查不到 → 文件夹页显示空态文案「在 Finder 中为文件夹添加标签」；不报错。
- **路径消失**（标签命中但文件夹已删）：行置灰，动作时 `NSWorkspace.open` 失败静默 + 日志；recents 条目打开失败 3 次自动清除。
- **helper 被 watchdog 重启**：launcher 面板随之重建（同 toolbar/card）；recents 在 UserDefaults 中存活；theme 由既有 `push_theme_to_helper` 重推。
- **与 result card/toolbar 同时可见**：互不感知，launcher 抢 key 后原面板按各自 resignKey 逻辑自理。
- **快捷键冲突**（用户装了用双击 Shift 的工具）：可在 Settings 改为其他 preset。
- **窗口多屏**：以 `NSEvent.mouseLocation` 所在屏幕定位。

## 8. 验证（手动 smoke，无既有测试基建）

1. `npm run tauri build`（或 dev）成功；helper 双文件编译通过。
2. Finder 给 2 个文件夹打不同标签 → 双击 Shift → 两分组出现、色点正确。
3. 连续输入 `Shift+H Shift+I`（快打 "HI"）→ 面板**不**弹出（防误触）。
4. ↑↓/Enter → Finder 打开；编辑器/终端按钮各自生效（未装编辑器时按钮隐藏）。
5. 打开过的文件夹进入 Recent 节，重启 helper 后仍在。
6. 应用页：frontmost 置顶，点击切入目标 App。
7. Esc / 点击面板外 → 面板隐藏，`launcher-hidden` 日志可见。
8. Settings 切换 launcher 快捷键 preset → 立即生效（无需重启）。
9. 回归：双击 Ctrl popup、选词 toolbar、result card、Notes 面板行为不变。
