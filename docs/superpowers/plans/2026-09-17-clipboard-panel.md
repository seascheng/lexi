# Clipboard Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Alt+V 唤起的原生粘贴板历史面板（第三面板）：后台采集文本/图片/文件引用 → 搜索/分类过滤 → Enter 回贴进唤起前应用。

**Architecture:** 顶层隔离、底层复用 —— 新 Rust 模块 `src-tauri/src/clipboard.rs`（快捷键 + TCP 发送）与 helper 侧三个新 Swift 文件（`ClipboardStore.swift` 存储 / `ClipboardMonitor.swift` 轮询采集 / `ClipboardPanel.swift` UI+回贴）承载全部逻辑；复用 CGEventTap、`post_to_helper`、`KeyablePanel`/`makePanelBackground`/`CardTheme` 面板基建、`/theme` 推送。ActionPanel/LauncherPanel 行为零改动。

**Tech Stack:** Rust（core-graphics CGEventTap、tauri commands、sqlite3 CLI）+ Swift/AppKit（NSPanel、NSTableView 变高行、NSPasteboard、SQLite3 C API、FTS5）+ React/TS 设置项。无新增 crate / npm 依赖。

**Spec:** `docs/superpowers/specs/2026-09-17-clipboard-panel-design.md`（本计划从规格论证，执行者两份都读）

## Global Constraints

- 不新增任何 crate 或 npm 依赖；Swift 链接 build.rs 现有 frameworks + `-lsqlite3`（系统 libsqlite3 自带 FTS5，tinycast 同款）。
- 顶层隔离：clipboard 代码只存在于 `src-tauri/src/clipboard.rs`、`src-tauri/native/Clipboard{Store,Monitor,Panel}.swift`；既有文件改动仅限本计划列出的接缝（lib.rs / native_toolbar.rs / text_injection.rs / SelectionToolbarHelper.swift / build.rs / 4 个前端文件）。
- 既有行为零回归：双击 Ctrl popup、双击 Shift launcher、选词 toolbar、result card、Notes、翻译注入三层不变。tap 中 **只有** clipboard 组合键 arm 返回 `CallbackResult::Remove`，其余 arm 一律保持 `CallbackResult::Keep`。
- 私有 pasteboard 标记：`com.lexi.clipboard.internal`（空 Data）；敏感守卫类型：`org.nspasteboard.ConcealedType`、`org.nspasteboard.TransientType`、`com.apple.is-sensitive`。
- 常量（tinycast 对齐）：轮询 0.5s（tolerance 0.1）；`maxTextLength = 32_000`；`maxCapturedFiles = 32`；volatile roots `/tmp/`、`/var/tmp/`、`/var/folders/`、`~/Library/Caches/`；常驻窗口 1000；剪枝 90 天（unpinned）；FTS `LIMIT 200`；激活延迟 80ms。
- 存储位置：`~/Library/Application Support/com.lexi.selection-helper/{clipboard.sqlite3,images/,icons/}`。
- TCP 端点：`POST /clipboard-show`（helper 端 toggle）、`POST /clipboard-hide`、`POST /clipboard-suspend`、`POST /clipboard-resume`（后两者 body `{"changeCount":N}`）；action 回报 `clipboard-hidden`。
- 新设置键 `clipboardShortcut`（string，默认 `"Alt+V"`）。
- UI 文案中文 chips（全部/固定/文本/链接/文件）+ 中文底部状态条（hapigo 风格），面板其余文案与既有面板一致用英文。
- 采集分支顺序不变量：internal 标记 → 敏感守卫 → file-url → text → image（file 永远先于 text 读）。
- 无测试基建的层面（Swift/AppKit、前端 UI）以编译 + 手动 smoke 为验证；纯 Rust 逻辑用 `cargo test`。
- 每个 task 结束提交一次 git commit。

---

### Task 1: Rust — `clipboard.rs` 快捷键模块 + tap/lib 接缝

**Files:**
- Create: `src-tauri/src/clipboard.rs`
- Modify: `src-tauri/src/lib.rs`（`mod launcher;` 旁 + setup 中 `launcher::initialize` 旁 + 命令注册）
- Modify: `src-tauri/src/native_toolbar.rs:1768-1771`（launcher arm 后加 clipboard arm）、`:2002-2018`（`handle_flags_changed` 末尾加委托）
- Test: `src-tauri/src/clipboard.rs` 内 `#[cfg(test)]`

**Interfaces:**
- Consumes: `native_toolbar::{ShortcutMode, shortcut_matches_keydown, modifier_flag, detect_double_press, log_native, toolbar_port, post_to_helper, current_popup_shortcut 所用同款 sqlite 读取模式}`；`launcher.rs` 为镜像模板。
- Produces（Task 2/6/7 依赖）:
  - `pub fn set_clipboard_shortcut(shortcut: String) -> Result<(), String>`（tauri command）
  - `pub(crate) fn initialize(app: &tauri::App)`
  - `pub(crate) fn is_clipboard_hotkey(event: &CGEvent) -> bool`
  - `pub(crate) fn handle_flags_changed(app: &tauri::AppHandle, event: &CGEvent)`
  - `pub(crate) fn show_clipboard()`、`pub(crate) fn post_suspend(count: i64)`、`pub(crate) fn post_resume(count: i64)`（Task 2 用）

- [ ] **Step 1: 写失败的单测**（`clipboard.rs` 末尾）

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use core_graphics::event::KeyCode;
    use crate::native_toolbar::ShortcutMode;

    #[test]
    fn default_is_alt_v_combo() {
        assert!(matches!(
            default_clipboard_shortcut(),
            ShortcutMode::KeyCombo { alt: true, cmd: false, shift: false, ctrl: false, key_code }
                if key_code == KeyCode::ANSI_V as u16
        ));
    }

    #[test]
    fn parse_accepts_presets() {
        for text in ["Alt+V", "Cmd+Shift+V", "Ctrl+Shift+V", "Alt+Alt", "Cmd+Cmd"] {
            assert!(ShortcutMode::parse(text).is_some(), "{text}");
        }
    }

}
```

（`is_clipboard_hotkey_with(mode, event)` 为可测内层：`shortcut_matches_keydown(mode, event)`，匹配语义已由 launcher 既有单测覆盖；不为 clipboard 重复构造 CGEvent——与 launcher 先例一致：parse/default 层单测，匹配层编译+smoke。）

- [ ] **Step 2: 跑测试确认失败**

Run: `cargo test --manifest-path src-tauri/Cargo.toml clipboard`
Expected: 编译错误（模块不存在）。

- [ ] **Step 3: 实现 `clipboard.rs`**（镜像 `launcher.rs` 全结构，差异如下）

```rust
//! Clipboard panel — Alt+V native clipboard history, rendered by the
//! selection helper's ClipboardPanel.swift. Top-level isolated subsystem:
//! this module owns hotkey state + TCP calls; capture/store/UI live in the
//! helper (ClipboardStore/Monitor/Panel.swift).

const DEFAULT_CLIPBOARD_SHORTCUT: &str = "Alt+V";
static CLIPBOARD_SHORTCUT: OnceLock<Mutex<ShortcutMode>> = OnceLock::new();
static LAST_CLIPBOARD_PRESS: Mutex<Option<Instant>> = Mutex::new(None);

fn default_clipboard_shortcut() -> ShortcutMode {
    ShortcutMode::parse(DEFAULT_CLIPBOARD_SHORTCUT).expect("default parses")
}
fn current_clipboard_shortcut() -> ShortcutMode { /* 同 launcher.rs:35-41 */ }

pub(crate) fn initialize(app: &tauri::App) { /* 同 launcher.rs:45-64，键名 "clipboardShortcut" */ }
fn read_clipboard_shortcut_from_sqlite(path: &Path) -> Option<String> { /* 同 launcher.rs:66-81 */ }

#[tauri::command]
pub fn set_clipboard_shortcut(shortcut: String) -> Result<(), String> { /* 同 launcher.rs:83-94 */ }

/// FlagsChanged hook（仅 DoubleModifier preset 用；Alt+V 组合键走 KeyDown）。
pub(crate) fn handle_flags_changed(_app: &AppHandle, event: &CGEvent) {
    let ShortcutMode::DoubleModifier { key_code } = current_clipboard_shortcut() else { return };
    let pressed = modifier_flag(key_code).map(|f| event.get_flags().contains(f)).unwrap_or(false);
    if !pressed { return; }
    if detect_double_press(&LAST_CLIPBOARD_PRESS) {
        log_native("double-modifier clipboard shortcut detected");
        std::thread::spawn(show_clipboard);
    }
}


pub(crate) fn is_clipboard_hotkey(event: &CGEvent) -> bool {
    is_clipboard_hotkey_with(&current_clipboard_shortcut(), event)
}
fn is_clipboard_hotkey_with(mode: &ShortcutMode, event: &CGEvent) -> bool {
    shortcut_matches_keydown(mode, event)
}

pub(crate) fn show_clipboard() { /* post_to_helper(port, "/clipboard-show", "{}")，同 launcher.rs:121-129 */ }

/// 租约互斥：注入期间挂起/恢复采集。body 携带租约前 changeCount。
pub(crate) fn post_suspend(count: i64) { post_clipboard_json("/clipboard-suspend", count) }
pub(crate) fn post_resume(count: i64) { post_clipboard_json("/clipboard-resume", count) }
fn post_clipboard_json(endpoint: &str, change_count: i64) {
    let Some(port) = toolbar_port() else { return };
    let body = format!(r#"{{"changeCount":{change_count}}}"#);
    if let Err(error) = post_to_helper(port, endpoint, &body) {
        log_native(&format!("clipboard {endpoint} failed: {error}"));
    }
}
```

- [ ] **Step 4: tap 接缝**（`native_toolbar.rs`）

`:1771`（launcher arm 之后）插入：

```rust
        CGEventType::KeyDown if crate::clipboard::is_clipboard_hotkey(event) => {
            // Only swallow in the whole tap: Option+V types "√" — the paste
            // target must never receive it. Everything else keeps passing.
            log_native("clipboard shortcut key detected");
            thread::spawn(crate::clipboard::show_clipboard);
            return CallbackResult::Remove;
        }
```

`handle_flags_changed`（:2017 `crate::launcher::handle_flags_changed` 之后）加一行：

```rust
    // Clipboard owns its double-modifier detection (Alt+Alt preset path).
    crate::clipboard::handle_flags_changed(app, event);
```

- [ ] **Step 5: lib.rs 注册**：`mod clipboard;`；`invoke_handler` 加 `clipboard::set_clipboard_shortcut`；setup 中 `launcher::initialize` 旁加 `clipboard::initialize(&app);`。

- [ ] **Step 6: 跑测试 + 编译**

Run: `cargo test --manifest-path src-tauri/Cargo.toml && cargo build --manifest-path src-tauri/Cargo.toml`
Expected: PASS（launcher 既有 shortcut_tests 不回归）。

- [ ] **Step 7: Commit** `feat(clipboard): hotkey module + tap seam (Alt+V default, only swallowing arm)`

### Task 2: Rust — 注入租约 suspend/resume

**Files:**
- Modify: `src-tauri/src/text_injection.rs:265-310`（`paste_tier`）

**Interfaces:**
- Consumes: `crate::clipboard::{post_suspend, post_resume}`（Task 1）、既有 `pasteboard_change_count`。
- Produces: 无（行为封闭）。

- [ ] **Step 1: 接线**。`let pre_text = read_pasteboard_string_via_pb();`（:274）之前：

```rust
    // Suspend clipboard capture for the lease window: the helper's poller
    // would otherwise record the injected text as a genuine user copy.
    crate::clipboard::post_suspend(unsafe { pasteboard_change_count() } as i64);
```

restore 块（:305-308）之后（函数所有返回路径前——把 restore 块后的尾段包进 closure 或提前计算 `result`，确保 resume 恰执行一次）：

```rust
    crate::clipboard::post_resume(unsafe { pasteboard_change_count() } as i64);
```

注意：`:281-284` 的提前 return（失焦中止）路径同样要 resume —— 在该 return 前补 `post_resume(...)`（恢复后 changeCount 若被第三方推进，resume 携带的新 count 让轮询器照常看见，符合规格 §4）。

- [ ] **Step 2: 编译 + 既有测试**

Run: `cargo test --manifest-path src-tauri/Cargo.toml`
Expected: PASS。

- [ ] **Step 3: Commit** `feat(clipboard): suspend capture during injection pasteboard lease`

### Task 3: Swift — `ClipboardStore.swift`（Foundation+SQLite3）

**Files:**
- Create: `src-tauri/native/ClipboardStore.swift`

**Interfaces:**
- Produces（Monitor/Panel 依赖，精确签名）:
  - `struct ClipboardItem: Equatable { enum Kind: String { case text, image, file }; let id: UUID; let kind: Kind; let text: String?; let imagePath: String?; let createdAt: Date; let sourceBundleID: String?; let pinnedAt: Date?; var filePath: String? { kind == .file ? text : nil } }`
  - `final class ClipboardStore { static func open() -> ClipboardStore?`（Application Support 目录，失败删档重建一次）; `var items: [ClipboardItem]`（常驻窗口，pinned 无限）; `func addText(_ text: String, sourceBundleID: String?)`; `func addFiles(_ paths: [String], sourceBundleID: String?)`; `func addImage(_ png: Data, sourceBundleID: String?) -> ClipboardItem?`; `func search(_ query: String, filter: ClipboardFilter) -> [ClipboardItem]`; `func promote(_ item: ClipboardItem)`; `func setPinned(_ item: ClipboardItem, pinned: Bool)`; `func delete(_ item: ClipboardItem)`; `func imageURL(for item: ClipboardItem) -> URL?`; `func prune()` }

- [ ] **Step 1: 实现**（tinycast `ClipboardStore.swift` 移植，结构）
  - SQLite3 C API（`import Foundation` + `import SQLite3`），WAL，`items` 表 + 部分索引 + `fts5 trigram` + ai/au/ad 触发器 —— SQL 用规格 §5 原文。
  - `load`：两条索引分支（`rowid >= floor` 全部 + `pinned_at IS NOT NULL AND rowid < floor`）`ORDER BY rid DESC`；`windowFloor` = 最新 unpinned 的 rowid `OFFSET 999`。
  - `search`：≥3 字符 → FTS `MATCH ? ORDER BY rowid DESC LIMIT 200`；否则内存过滤窗口。`ClipboardFilter`（定义在本文件）：`enum ClipboardFilter { case all, pinned, text, link, file }` + `func matches(_ item: ClipboardItem) -> Bool`（link 为派生：`text` 有 `^[a-z][a-z0-9+.-]*://` 或 `mailto:` 前缀且 ≤2048 字节、无内嵌空白 → true；file 匹配 kind==.file；pinned 匹配 pinnedAt != nil）。**过滤在 pinned/rest 切分之后做**（与 search memo key 合并）。
  - `promote`：pinned 跳过；同 id `DELETE`+`INSERT` 单事务（FTS 触发器自动同步）；blob 不动。
  - `addText`：`items.first` 同 kind+text → return；否则插入。
  - `addImage`：写 `images/<uuid>.png`，插行；`delete`/`prune` 时删除**自有** `images/` 文件（`imagePath` 前缀检查），file 条目永不删原文件。
  - `prune`：`DELETE FROM items WHERE created_at < ? AND pinned_at IS NULL`（90 天），连带自有 image blob；off-main 可后置。
  - 库打不开：删除文件重建一次；再失败 → 内存模式（`items` 空数组起步，操作全部 no-op 安全）。
- [ ] **Step 2: 编译验证**（本 task 尚未进 build.rs，用 swiftc 单文件语法检查）

Run: `xcrun swiftc -parse src-tauri/native/ClipboardStore.swift`
Expected: 无错误。

- [ ] **Step 3: Commit** `feat(clipboard): SQLite+FTS5 history store (tinycast port)`

### Task 4: Swift — `ClipboardMonitor.swift`（轮询采集）

**Files:**
- Create: `src-tauri/native/ClipboardMonitor.swift`

**Interfaces:**
- Consumes: `ClipboardStore`（Task 3）。
- Produces: `final class ClipboardMonitor { static let shared = ClipboardMonitor(); func start(store: ClipboardStore); func suspend(changeCount: Int64); func resume(changeCount: Int64); static let internalType = NSPasteboard.PasteboardType("com.lexi.clipboard.internal") }`；`func cachedIcon(forBundleID: String) -> NSImage?`（Panel 也用）。

- [ ] **Step 1: 实现**（tinycast `ClipboardManager.poll` 移植）
  - `start`: `lastChangeCount = NSPasteboard.general.changeCount`（重启基线：间隙写入不补采）；`Timer(timeInterval: 0.5, repeats: true, tolerance: 0.1)` → `poll()`。
  - `poll()` 顺序：`changeCount` 未变 return → 更新基线 → `types.contains(internalType)` return → 敏感三类型 disjoint 检查 return → `sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier` → `fileURLs(on:)` 非空则 `addFiles`（reversed 插入）→ `.string` 非空白且 ≤32000 → `addText` → `.png/.tiff` → detached task TIFF→PNG → `addImage`。
  - `fileURLs`：每 item 自己的 `public.file-url`；`resolvingSymlinksInPath` 后拒绝 volatile roots 前缀；`prefix(32)`；空则返回 nil；结果 `reversed()`。
  - `suspend/changeCount`：记 `suspendedUntilCount = changeCount`；`resume/changeCount`：若 `NSPasteboard.general.changeCount == changeCount` 则 `lastChangeCount = changeCount`（租约期间无外来写入 → 跳过）；否则不动基线（真实写入下轮正常采）。
  - 图标缓存：`icons/<bundleID>.png`；未命中时 `NSWorkspace.urlForApplication(withBundleIdentifier:)` → `NSWorkspace.shared.icon(forFile:)` 渲染 72×72 PNG 落盘（主线程外）；未知 bundle → nil（Panel 用通用字形）。
- [ ] **Step 2: swiftc -parse 验证**。 Commit: `feat(clipboard): 0.5s pasteboard poll engine with sensitive guards + lease suspend`

### Task 5: Swift — `ClipboardPanel.swift`（UI + 回贴）

**Files:**
- Create: `src-tauri/native/ClipboardPanel.swift`

**Interfaces:**
- Consumes: `ClipboardStore`、`ClipboardMonitor.shared.cachedIcon`、`ClipboardFilter`；共享基建 `KeyablePanel`/`makePanelBackground`/`CardTheme`/`FileLog`（SelectionToolbarHelper.swift，fileprivate→internal 已在 launcher 任务提升）。
- Produces: `final class ClipboardPanelController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate { var onHidden: (() -> Void)?; func show(); func hide(notify: Bool); func applyTheme(dark: Bool) }`。

- [ ] **Step 1: 骨架** —— 逐段镜像 `LauncherPanel.swift`（同构点直接抄）：
  - init/panel 常量：`panelWidth = 520`；chrome = search(12+26+8) + chips(24+8) + footer(24) + pads ≈ 110；`maxListHeight = 11 × 44`；高自适应 min 200 / max 560。
  - `show()`: 重置搜索 → `previousApp = NSWorkspace.shared.frontmostApplication` → `reload()` → `placePanel()`（launcher :250-260 同款鼠标屏定位）→ `makeKeyAndOrderFront` + firstResponder。
  - `windowDidResignKey` → `hide(notify: true)`；`applyTheme(dark:)` → scrim + reloadData（launcher :132-139 同款）。
  - **toggle**：`show()` 首行 `if panel.isVisible { hide(notify: true); return }`。
- [ ] **Step 2: chrome**
  - 搜索框同 launcher :146-153（placeholder「输入关键词搜索」）。
  - chips 行：`[("全部", .gray, .all), ("固定", #FF6EC7, .pinned), ("文本", #4AA3FF, .text), ("链接", #34C759, .link), ("文件", #FF9500, .file)]`，胶囊 NSButton（isBordered=false, cornerRadius 12, 高 24）：8pt 色点（layer 子视图）+ 12pt 文字；选中 `selectedFill`、未选 `hoverFill` on hover；`filter` 属性 didSet → reload。
  - footer：24pt NSTextField×2（左 `已选 \(selected+1) 项，总共 \(visible.count) 项`；右 `⌘P 固定 · ⌫ 删除 · ↩ 粘贴`，`tertiaryText` 11pt），顶部 `hairline` 1pt 分隔线；`layoutChrome` 中定位。
- [ ] **Step 3: 数据行**
  - `enum Row { case sectionHeader(String); case clip(ClipboardItem) }`；`visible: [Row]` = pinned 节（「固定」）+ 其余 recency，经 `store.search(filterText, filter:)`。
  - 变高：短文本/文件名行 32pt；文本 >42 字符或含换行 → 3 行 44pt（13pt 字，尾截断 `byTruncatingTail`，多行 NSTextField）；image 行 44pt。`heightOfRow` 按 row 类型。
  - 行绘制（自绘 view，launcher row 模式）：20pt 来源图标（`cachedIcon(forBundleID:)` ?? 通用 doc 字形）+ 预览（file：文件名 + 灰路径两行；link：文本单行；color 无 v1）。
  - 选中：`selectedFill` 圆角胶囊（frame 内 inset 2pt，非整行系统蓝——launcher `syncTabButtons` 同语法）。
  - 空态 `emptyLabel`「暂无粘贴板历史 — 复制任意内容开始」。
- [ ] **Step 4: 键盘 + 动作**
  - `↑↓` 跨节移动（跳过 header；scrollRectToVisible 跟随）；`Enter` → paste；`Esc` 清搜索或隐藏；`Tab` → chips 循环；`⌘P` → `store.setPinned(selected, pinned: !pinned)` + reload（unpin 后选中跟随新索引）；`⌫` → `store.delete(selected)` + reload。
  - **Paster**（本文件内 `enum ClipboardPaster`，tinycast 契约）：
```swift
    static func paste(_ item: ClipboardItem, store: ClipboardStore, previousApp: NSRunningApplication?) -> Bool {
        guard write(item, store: store) else { return false }
        previousApp?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { postCommandV() }
        return true
    }
    /// declare 按 kind：text=[.string]；image=[.png]；file=[.fileURL, .string(路径)]，
    /// 一律追加 internalType 空 Data；写后 store.promote(item)（poller 跳过标记写入，
    /// 这是唯一提升点；pinned 的 promote 在 store 内跳过）。
    /// postCommandV: CGEventSource(combinedSessionState) + V down/up + .maskCommand，
    /// 参照 tinycast Paster.postCommandV（flags 先于 key down 设置的完整序列）。
```
  - 文件消失：`write` 返回 false → footer 左侧临时文案「文件已不存在」2s（不删行）。
- [ ] **Step 5: swiftc -parse 验证**。 Commit: `feat(clipboard): panel UI (chips/variable rows/footer) + paste-back`

### Task 6: Swift — helper 接线 + build.rs

**Files:**
- Modify: `src-tauri/native/SelectionToolbarHelper.swift`（:880 launcherController 旁、:2622 launcher 分支旁、:2812 applyTheme 末尾、`applicationDidFinishLaunching`）
- Modify: `src-tauri/build.rs:52-68`（swiftc args）

**Interfaces:**
- Consumes: `ClipboardPanelController`（Task 5）、`ClipboardStore.open()`/`ClipboardMonitor.shared.start`（Task 3/4）。
- Produces: TCP 端点行为（Task 1 的发送对应物）。

- [ ] **Step 1: 接线**
  - app delegate：`private lazy var clipboardController: ClipboardPanelController = { let c = ClipboardPanelController(); c.onHidden = { [weak self] in self?.postAction(action: "clipboard-hidden", text: "-") }; return c }()`
  - `handleRequestData` 4 分支：`/clipboard-show` → `clipboardController.show()`；`/clipboard-hide` → `hide(notify: false)`；`/clipboard-suspend`、`/clipboard-resume` → 解析 body JSON `changeCount` → `ClipboardMonitor.shared.suspend/resume`。
  - `applyTheme` 末尾（:2812 launcher 通知旁）：`clipboardController.applyTheme(dark: theme == .dark)`。
  - `applicationDidFinishLaunching`：TCP server 启动之后 `if let store = ClipboardStore.open() { ClipboardMonitor.shared.start(store: store) }`（失败仅 FileLog）。
- [ ] **Step 2: build.rs**：swiftc args 加 `"native/ClipboardStore.swift"`, `"native/ClipboardMonitor.swift"`, `"native/ClipboardPanel.swift"`, `"-lsqlite3"`；rerun-if-changed 加三个文件。
- [ ] **Step 3: 编译**。Run: `cargo build --manifest-path src-tauri/Cargo.toml`（触发 swiftc）。Expected: helper 编译 + 签名成功。 Commit: `feat(clipboard): wire panel into helper + build`

### Task 7: 前端 — 设置项

**Files:**
- Modify: `src/types.ts`（AppSettings + `clipboardShortcut: string`）、`src/lib/defaults.ts`（默认 `"Alt+V"`）、`src/pages/SettingsPage.tsx:221-231`（launcher 行后加同款 Select）、`src/App.tsx`（启动同步 `set_clipboard_shortcut`，`set_launcher_shortcut` 旁）。

- [ ] **Step 1: 四文件各 ≤6 行**，Select options：`Alt+V`（默认/Option+V）/ `Cmd+Shift+V` / `Ctrl+Shift+V` / `Alt+Alt`（Double Option）/ `Cmd+Cmd`（Double Cmd），hint「Opens the clipboard panel from any app.」
- [ ] **Step 2: 验证**。Run: `npm run build`（或 vite build）。Expected: 编译通过。 Commit: `feat(clipboard): clipboardShortcut setting`

### Task 8: 构建 + 手动 smoke（规格 §10 清单）

- [ ] **Step 1**: `npm run tauri build`（或 dev）。Expected: 全链编译。
- [ ] **Step 2**: 按 spec §10 九条逐项 smoke（复制采集/吞键/回贴/固定/删除/过滤/敏感/租约/toggle/三面板回归），记录结果。
- [ ] **Step 3**: 收尾 commit（如有修补）。
