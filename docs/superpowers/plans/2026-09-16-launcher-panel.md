# Launcher Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Double-Shift 唤起的原生 launcher 面板：Finder 标签文件夹 + 最近打开 + 运行中 App 即时切换。

**Architecture:** 顶层隔离、底层复用 —— 新模块 `src-tauri/src/launcher.rs`（Rust）与 `src-tauri/native/LauncherPanel.swift`（helper 内独立 controller）承载全部 launcher 逻辑；只复用 CGEventTap、helper TCP 传输（`post_to_helper`）、面板基建（`KeyablePanel`/`makePanelBackground`/`CardTheme`/lucide 渲染）与 `/theme` 推送链路。翻译/选词/笔记/复习链路零行为改动。

**Tech Stack:** Rust (core-graphics CGEventTap, tauri commands) + Swift/AppKit (NSPanel, NSMetadataQuery, NSWorkspace, NSTableView) + React/TS 设置项。无新增 crate / npm 依赖。

**Spec:** `docs/superpowers/specs/2026-09-16-launcher-panel-design.md`

## Global Constraints

- 不新增任何 crate 或 npm 依赖；Swift 仅用 AppKit/Foundation/Network（build.rs 现有 frameworks）。
- 顶层隔离：launcher 代码只存在于 `src-tauri/src/launcher.rs`、`src-tauri/native/LauncherPanel.swift`；既有文件的改动仅限本计划列出的接缝。
- 既有行为零回归：双击 Ctrl popup、Cmd+Shift+T、选词 toolbar、result card、Notes 面板全部不变（含 `ShortcutMode::parse("ctrl+ctrl")`、"control+control" 语义）。
- 新设置键：`launcherShortcut`（string，默认 `"Shift+Shift"`）；TCP 端点 `POST /launcher-show`、`POST /launcher-hide`；action 回报 `launcher-hidden`。
- UI 文案英文；视觉遵循 helper 现有 goty 风格（`CardTheme` 派生色、lucide 图标、hairline、selectedFill 胶囊）。
- 无新系统权限（复用已授的 Accessibility；NSWorkspace/NSMetadataQuery 无需 TCC）。
- 键码事实（core-graphics 0.25）：`KeyCode::COMMAND=0x37, RIGHT_COMMAND=0x36, SHIFT=0x38, RIGHT_SHIFT=0x3C, OPTION=0x3A, RIGHT_OPTION=0x3D, CONTROL=0x3B, RIGHT_CONTROL=0x3E`（`RIGHT_CONTROL` 以裸值 0x3E 书写，避免依赖常量名）。
- 无测试基建的层面（Swift/AppKit、前端 UI）以编译 + 手动 smoke 为验证；纯 Rust 逻辑用 `cargo test` 单元测试。
- 每个 task 结束提交一次 git commit。

---

### Task 1: Rust — ShortcutMode 泛化 + 双击检测核心（含打字防误触）

**Files:**
- Modify: `src-tauri/src/native_toolbar.rs`（`ShortcutMode` 约 688-758、`handle_flags_changed` 约 1917-1956、`handle_system_event` 约 1531-1537、`is_translate_shortcut` 约 1886-1898）
- Test: 同文件 `#[cfg(test)]` 模块（新建，置于文件末尾）

**Interfaces:**
- Produces（后续 task 依赖的精确签名，全部 `pub(crate)`）:
  - `enum ShortcutMode { KeyCombo { cmd: bool, shift: bool, ctrl: bool, alt: bool, key_code: u16 }, DoubleModifier { key_code: u16 } }`
  - `ShortcutMode::parse(&str) -> Option<Self>` 额外接受 `"Shift+Shift"`/`"Alt+Alt"`/`"Cmd+Cmd"`（及 `"Option+Option"`/`"Command+Command"`/`"Control+Control"`）
  - `fn modifier_flag(key_code: u16) -> Option<CGEventFlags>`
  - `fn detect_double_press(last_press: &Mutex<Option<Instant>>) -> bool`
  - `fn shortcut_matches_keydown(mode: &ShortcutMode, event: &CGEvent) -> bool`
  - 常量 `DOUBLE_PRESS_INTERVAL_MS: u64 = 300`（替代 `DOUBLE_CTRL_INTERVAL_MS`）
  - 静态 `LAST_NONMOD_KEYDOWN: Mutex<Option<Instant>>`（KeyDown 时记录）

- [ ] **Step 1: 写失败的单元测试**

在 `native_toolbar.rs` 文件末尾追加：

```rust
// ---------------------------------------------------------------------------
// Tests — shortcut parsing + double-press detection
// ---------------------------------------------------------------------------

#[cfg(test)]
mod shortcut_tests {
    use super::*;

    #[test]
    fn parse_doubled_modifiers() {
        for (text, expected) in [
            ("ctrl+ctrl", KeyCode::CONTROL as u16),
            ("Control+Control", KeyCode::CONTROL as u16),
            ("Shift+Shift", KeyCode::SHIFT as u16),
            ("Alt+Alt", KeyCode::OPTION as u16),
            ("Option+Option", KeyCode::OPTION as u16),
            ("Cmd+Cmd", KeyCode::COMMAND as u16),
        ] {
            match ShortcutMode::parse(text) {
                Some(ShortcutMode::DoubleModifier { key_code }) => assert_eq!(key_code, expected, "{text}"),
                other => panic!("{text} parsed to {other:?}"),
            }
        }
    }

    #[test]
    fn parse_combo_and_rejects() {
        // legacy default still parses as a combo
        assert!(matches!(
            ShortcutMode::parse("Cmd+Shift+T"),
            Some(ShortcutMode::KeyCombo { cmd: true, shift: true, ctrl: false, alt: false, key_code })
                if key_code == KeyCode::ANSI_T as u16
        ));
        assert!(ShortcutMode::parse("shift").is_none());          // single token
        assert!(ShortcutMode::parse("").is_none());
        assert!(ShortcutMode::parse("a+b").is_none());            // no modifier
    }

    // Runs as ONE test: detect_double_press + LAST_NONMOD_KEYDOWN are global,
    // parallel #[test]s would race on the shared static.
    #[test]
    fn double_press_sequences() {
        let last: Mutex<Option<Instant>> = Mutex::new(None);

        // clean double press fires; triple press does not re-fire
        assert!(!detect_double_press(&last), "first press arms");
        assert!(detect_double_press(&last), "clean second press fires");
        assert!(!detect_double_press(&last), "third press only arms");

        // typing between the two presses rejects AND re-arms
        assert!(!detect_double_press(&last), "arm again");
        if let Ok(mut cell) = LAST_NONMOD_KEYDOWN.lock() {
            *cell = Some(Instant::now());
        }
        assert!(!detect_double_press(&last), "dirty second press does not fire");
        assert!(detect_double_press(&last), "clean follow-up press fires");
    }
}
```

- [ ] **Step 2: 跑测试确认编译失败**

Run: `cargo test --manifest-path src-tauri/Cargo.toml shortcut_tests`
Expected: 编译错误（`DoubleModifier`/`detect_double_press`/`modifier_flag` 未定义）。

- [ ] **Step 3: 实现**

3a. 替换 `ShortcutMode` 枚举（现 688-701 行）与 `parse`（现 714-720 行的双击分支）：

```rust
/// Parsed keyboard shortcut for a global hotkey.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum ShortcutMode {
    /// Traditional modifier+key combo, e.g. Cmd+Shift+T
    KeyCombo {
        cmd: bool,
        shift: bool,
        ctrl: bool,
        alt: bool,
        key_code: u16,
    },
    /// Double-press a modifier within a time window ("Ctrl+Ctrl",
    /// "Shift+Shift", …). `key_code` is the pair's canonical (left) keycode;
    /// detection matches on the FLAG bit, so left/right both count.
    DoubleModifier { key_code: u16 },
}
```

`parse` 内，删除现有 `if lower == "ctrl+ctrl" || lower == "control+control"` 分支，替换为：

```rust
        // Double-modifier patterns: "Ctrl+Ctrl", "Shift+Shift", "Alt+Alt", "Cmd+Cmd"
        let doubled: Vec<&str> = lower.split('+').collect();
        if doubled.len() == 2 && doubled[0] == doubled[1] {
            if let Some(key_code) = modifier_name_to_code(doubled[0]) {
                return Some(Self::DoubleModifier { key_code });
            }
        }
```

在 `impl ShortcutMode` 块之后新增自由函数：

```rust
/// Canonical keycode for a modifier name. Only doubled-form shortcuts
/// ("shift+shift") consult this — combos use `key_name_to_code`.
fn modifier_name_to_code(name: &str) -> Option<u16> {
    match name {
        "ctrl" | "control" => Some(KeyCode::CONTROL as u16),
        "shift" => Some(KeyCode::SHIFT as u16),
        "alt" | "option" => Some(KeyCode::OPTION as u16),
        "cmd" | "command" => Some(KeyCode::COMMAND as u16),
        _ => None,
    }
}
```

3b. `is_translate_shortcut`（1886-1898）改为委托，抽出通用匹配：

```rust
fn is_translate_shortcut(event: &CGEvent) -> bool {
    shortcut_matches_keydown(&current_popup_shortcut(), event)
}

/// True when a KeyDown event matches the combo form of `mode`.
/// DoubleModifier modes never match — they live in FlagsChanged.
pub(crate) fn shortcut_matches_keydown(mode: &ShortcutMode, event: &CGEvent) -> bool {
    let ShortcutMode::KeyCombo { cmd, shift, ctrl, alt, key_code } = mode else {
        return false;
    };
    let event_key_code = event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYCODE) as u16;
    let flags = event.get_flags();
    event_key_code == key_code
        && (!cmd || flags.contains(CGEventFlags::CGEventFlagCommand))
        && (!shift || flags.contains(CGEventFlags::CGEventFlagShift))
        && (!ctrl || flags.contains(CGEventFlags::CGEventFlagControl))
        && (!alt || flags.contains(CGEventFlags::CGEventFlagAlternate))
}
```

3c. `DOUBLE_CTRL_INTERVAL_MS`（1918）重命名为 `DOUBLE_PRESS_INTERVAL_MS`（值仍 300，注释改为 "Maximum time between two presses of a modifier to count as a double-press (ms)."）。`LAST_CTRL_PRESS` 静态保留不动。

新增共享核心（放在该常量旁）：

```rust
/// Latest non-modifier KeyDown (every KeyDown is non-modifier — modifiers
/// arrive as FlagsChanged). Double-modifier shortcuts reject intervals that
/// contain typing: fast `Shift+H Shift+I` capital bursts must never fire.
static LAST_NONMOD_KEYDOWN: Mutex<Option<Instant>> = Mutex::new(None);

/// The flag bit a modifier keycode maps to (left/right variants share it).
/// Raw values: kVK_Control 0x3B / 0x3E, kVK_Shift 0x38 / 0x3C,
/// kVK_Option 0x3A / 0x3D, kVK_Command 0x37 / 0x36.
pub(crate) fn modifier_flag(key_code: u16) -> Option<CGEventFlags> {
    match key_code {
        0x3B | 0x3E => Some(CGEventFlags::CGEventFlagControl),
        0x38 | 0x3C => Some(CGEventFlags::CGEventFlagShift),
        0x3A | 0x3D => Some(CGEventFlags::CGEventFlagAlternate),
        0x37 | 0x36 => Some(CGEventFlags::CGEventFlagCommand),
        _ => None,
    }
}

/// Double-press detector with typing protection. Fires only when the second
/// press lands within DOUBLE_PRESS_INTERVAL_MS AND no non-modifier KeyDown
/// happened between the two presses. A clean fire resets (no triple-press);
/// a dirty second press re-arms as a new first press.
pub(crate) fn detect_double_press(last_press: &Mutex<Option<Instant>>) -> bool {
    let now = Instant::now();
    let last_keydown = LAST_NONMOD_KEYDOWN.lock().ok().and_then(|cell| *cell);
    let Ok(mut last) = last_press.lock() else { return false };
    match *last {
        Some(prev) if now.duration_since(prev).as_millis() as u64 <= DOUBLE_PRESS_INTERVAL_MS => {
            match last_keydown {
                Some(t) if t > prev => {
                    *last = Some(now); // typing between presses — dirty
                    false
                }
                _ => {
                    *last = None; // reset: prevent triple-press
                    true
                }
            }
        }
        _ => {
            *last = Some(now);
            false
        }
    }
}
```

3d. `handle_system_event`（1531）函数体 `match event_type` 之前插入记录：

```rust
    // Every KeyDown is a non-modifier key (modifiers arrive as FlagsChanged).
    // Double-modifier shortcuts reject intervals that contain typing.
    if event_type == CGEventType::KeyDown {
        if let Ok(mut cell) = LAST_NONMOD_KEYDOWN.lock() {
            *cell = Some(Instant::now());
        }
    }
```

3e. `handle_flags_changed`（1921-1956）整体替换（保留原注释精神）：

```rust
/// Handle modifier state changes for double-modifier shortcuts
/// (popup's Ctrl+Ctrl; launcher's own detection is delegated).
fn handle_flags_changed(app: &tauri::AppHandle, event: &CGEvent) {
    if let ShortcutMode::DoubleModifier { key_code } = current_popup_shortcut() {
        let pressed = modifier_flag(key_code)
            .map(|flag| event.get_flags().contains(flag))
            .unwrap_or(false);
        if pressed && detect_double_press(&LAST_CTRL_PRESS) {
            log_native("double-modifier popup shortcut detected");
            let app = app.clone();
            thread::spawn(move || {
                trigger_popup_with_selection(&app);
            });
        }
    }

    // Launcher owns its double-modifier detection + trigger (top-level isolation).
    crate::launcher::handle_flags_changed(app, event);
}
```

此调用引用了尚不存在的 `crate::launcher` 模块——本 task 同时创建其最小骨架（仅空实现，保持本 task 独立可编译），Task 2 再整体替换为完整实现：

```rust
//! Launcher panel — double-Shift native launcher (folders + running apps).
//! Top-level isolated subsystem; see
//! docs/superpowers/specs/2026-09-16-launcher-panel-design.md

use core_graphics::event::CGEvent;
use tauri::AppHandle;

/// FlagsChanged hook — called by the event tap. The full double-modifier
/// detection lands in Task 2; this shell keeps the tap seam compiling.
pub(crate) fn handle_flags_changed(_app: &AppHandle, _event: &CGEvent) {}
```

并在 `lib.rs` 顶部（`mod native_toolbar;` 之后）加 `mod launcher;`。

- [ ] **Step 4: 跑测试确认通过**

Run: `cargo test --manifest-path src-tauri/Cargo.toml`
Expected: `shortcut_tests` 3 个测试 PASS，无编译错误。

- [ ] **Step 5: 手动回归确认（可选快速）**

Run: `cargo build --manifest-path src-tauri/Cargo.toml`
Expected: 成功。（双击 Ctrl 行为的完整回归在 Task 7 smoke 覆盖。）

- [ ] **Step 6: Commit**

```bash
git add src-tauri/src/native_toolbar.rs src-tauri/src/launcher.rs src-tauri/src/lib.rs
git commit -m "refactor(native_toolbar): generalize double-modifier shortcut detection with typing guard"
```

---

### Task 2: Rust — launcher 模块（状态/命令/触发）+ tap 接缝

**Files:**
- Modify: `src-tauri/src/launcher.rs`（替换 Task 1 骨架为完整实现）
- Modify: `src-tauri/src/native_toolbar.rs`（`toolbar_port`/`post_to_helper` 提升 `pub(crate)`；KeyDown 分支新增 launcher hotkey arm）
- Modify: `src-tauri/src/lib.rs`（注册命令 + `launcher::initialize`）

**Interfaces:**
- Consumes: Task 1 的 `ShortcutMode`/`parse`/`modifier_flag`/`detect_double_press`/`shortcut_matches_keydown`；native_toolbar 的 `log_native`。
- Produces:
  - `pub(crate) fn launcher::initialize(app: &tauri::App)`（setup 时读 sqlite）
  - `pub(crate) fn launcher::handle_flags_changed(app: &AppHandle, event: &CGEvent)`
  - `pub(crate) fn launcher::is_launcher_hotkey(event: &CGEvent) -> bool`
  - `pub(crate) fn launcher::show_launcher()`
  - `#[tauri::command] pub fn launcher::set_launcher_shortcut(shortcut: String) -> Result<(), String>`
  - native_toolbar: `pub(crate) fn toolbar_port() -> Option<u16>`、`pub(crate) fn post_to_helper(port: u16, path: &str, body: &str) -> std::io::Result<()>`

- [ ] **Step 1: 提升 native_toolbar 底层原语可见性**

`fn toolbar_port()`（约 336 行）→ `pub(crate) fn toolbar_port()`；`fn post_to_helper(...)`（约 3062 行）→ `pub(crate) fn post_to_helper(...)`。函数体不变。

- [ ] **Step 2: tap 与 action 通道的 launcher 接缝**

2a. `handle_system_event` 的 `CGEventType::KeyDown if is_translate_shortcut(event)` arm（约 1736-1742）之后、`is_copy_command` arm 之前插入：

```rust
        CGEventType::KeyDown if crate::launcher::is_launcher_hotkey(event) => {
            log_native("launcher shortcut key detected");
            thread::spawn(crate::launcher::show_launcher);
        }
```

2b. `dispatch_toolbar_action`（约 3064 起）内，`"card-hidden" || "card-cleared"` 分支之后插入（helper 自报隐藏；Rust 端仅记日志，spec §5）：

```rust
    // Launcher panel dismissal report — informational only (no state to clear).
    if action.action == "launcher-hidden" {
        log_native("launcher hidden");
        return Ok(());
    }
```

- [ ] **Step 3: 完整 launcher.rs**

用以下内容**整体替换** `launcher.rs`：

```rust
//! Launcher panel — double-Shift native launcher (tagged folders, recents,
//! running apps), rendered by the selection helper's LauncherPanel.swift.
//!
//! Top-level isolated subsystem: everything launcher-specific lives here and
//! in the helper. Reused bottom layers only: the CGEventTap (native_toolbar),
//! the helper TCP transport (`post_to_helper`) and the `/theme` push pipeline
//! (the helper applies themes to the launcher panel itself).

use std::path::Path;
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

use core_graphics::event::CGEvent;
use tauri::{AppHandle, Manager};

use crate::native_toolbar::{
    detect_double_press, log_native, modifier_flag, post_to_helper, shortcut_matches_keydown,
    toolbar_port, ShortcutMode,
};

const DEFAULT_LAUNCHER_SHORTCUT: &str = "Shift+Shift";

static LAUNCHER_SHORTCUT: OnceLock<Mutex<ShortcutMode>> = OnceLock::new();
/// Last press of the launcher's double-modifier shortcut (see
/// `detect_double_press` for the typing guard).
static LAST_LAUNCHER_PRESS: Mutex<Option<Instant>> = Mutex::new(None);

fn default_launcher_shortcut() -> ShortcutMode {
    ShortcutMode::DoubleModifier {
        key_code: 0x38, // kVK_Shift
    }
}

fn current_launcher_shortcut() -> ShortcutMode {
    LAUNCHER_SHORTCUT
        .get_or_init(|| Mutex::new(default_launcher_shortcut()))
        .lock()
        .map(|mode| *mode)
        .unwrap_or_else(default_launcher_shortcut)
}

/// Read once from sqlite at startup — same sqlite3-CLI pattern as the popup
/// shortcut (the frontend also pushes the live value via the command below).
pub(crate) fn initialize(app: &tauri::App) {
    let path = app
        .path()
        .app_data_dir()
        .ok()
        .map(|dir| dir.join("lexi.db"));
    let saved = path
        .as_deref()
        .and_then(read_launcher_shortcut_from_sqlite)
        .unwrap_or_else(|| DEFAULT_LAUNCHER_SHORTCUT.to_string());
    if let Some(mode) = ShortcutMode::parse(&saved) {
        if let Ok(mut current) = LAUNCHER_SHORTCUT
            .get_or_init(|| Mutex::new(default_launcher_shortcut()))
            .lock()
        {
            *current = mode;
        }
    }
    log_native(&format!("launcher shortcut initialized ({saved})"));
}

fn read_launcher_shortcut_from_sqlite(path: &Path) -> Option<String> {
    let output = Command::new("sqlite3")
        .arg(path)
        .arg("SELECT value FROM settings WHERE key = 'launcherShortcut' LIMIT 1;")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

#[tauri::command]
pub fn set_launcher_shortcut(shortcut: String) -> Result<(), String> {
    let mode = ShortcutMode::parse(&shortcut)
        .ok_or_else(|| format!("Invalid shortcut format: {shortcut}"))?;
    let mut current = LAUNCHER_SHORTCUT
        .get_or_init(|| Mutex::new(default_launcher_shortcut()))
        .lock()
        .map_err(|_| "launcher shortcut state is unavailable".to_string())?;
    *current = mode;
    log_native(&format!("set launcher shortcut={shortcut}"));
    Ok(())
}

/// FlagsChanged hook from the tap. Owns the launcher's double-modifier
/// detection, fully independent of the popup's.
pub(crate) fn handle_flags_changed(_app: &AppHandle, event: &CGEvent) {
    let ShortcutMode::DoubleModifier { key_code } = current_launcher_shortcut() else {
        return;
    };
    let pressed = modifier_flag(key_code)
        .map(|flag| event.get_flags().contains(flag))
        .unwrap_or(false);
    if !pressed {
        return; // only act on press, not release
    }
    if detect_double_press(&LAST_LAUNCHER_PRESS) {
        log_native("double-modifier launcher shortcut detected");
        std::thread::spawn(show_launcher);
    }
}

/// Combo-form launcher shortcuts (e.g. Cmd+Shift+L) match on KeyDown.
pub(crate) fn is_launcher_hotkey(event: &CGEvent) -> bool {
    shortcut_matches_keydown(&current_launcher_shortcut(), event)
}

/// POST /launcher-show — the helper's LauncherPanelController gathers data
/// and takes key focus on its side. Runs on a worker thread (TCP write).
pub(crate) fn show_launcher() {
    let Some(port) = toolbar_port() else {
        log_native("launcher show skipped (helper port unknown)");
        return;
    };
    if let Err(error) = post_to_helper(port, "/launcher-show", "{}") {
        log_native(&format!("launcher show failed: {error}"));
    }
}
```

- [ ] **Step 4: lib.rs 注册**

`use commands::speech::speak_text;` 附近新增 `use launcher::set_launcher_shortcut;`；`generate_handler![...]` 列表（`set_popup_shortcut,` 之后）加入 `set_launcher_shortcut,`；`.setup(|app| { ... })` 内 `native_toolbar::setup_native_toolbar(app)?;` 之后加：

```rust
            launcher::initialize(app);
```

- [ ] **Step 5: 编译 + 测试**

Run: `cargo test --manifest-path src-tauri/Cargo.toml && cargo build --manifest-path src-tauri/Cargo.toml`
Expected: 全部 PASS，编译成功。

- [ ] **Step 6: Commit**

```bash
git add src-tauri/src/launcher.rs src-tauri/src/native_toolbar.rs src-tauri/src/lib.rs
git commit -m "feat(launcher): rust module — double-shift hotkey state, set_launcher_shortcut command, /launcher-show transport"
```

---

### Task 3: Swift — 共享原语提升 + LauncherPanel 外壳 + helper 集成

**Files:**
- Modify: `src-tauri/native/SelectionToolbarHelper.swift`（fileprivate→internal 提升；`handleRequestData` 两分支；`applyTheme` 一行；`launcherController` 属性）
- Create: `src-tauri/native/LauncherPanel.swift`（可编译外壳）
- Modify: `src-tauri/build.rs`（双文件编译）

**Interfaces:**
- Consumes: Task 2 的 `POST /launcher-show`（body `{}`）。
- Produces（Task 4/5 依赖）:
  - `final class LauncherPanelController`：`func show()`、`func hide(notify: Bool)`、`func applyTheme(dark: Bool)`、`var onHidden: (() -> Void)?`
  - 文件内可用的共享原语（internal）：`KeyablePanel`、`makePanelBackground(frame:cornerRadius:)`、`CardTheme`（含 `static dark/light` 及派生色）、`lucideImage(for:title:color:)`、`lucideMarkup(for:)`、`hexString(_:)`、`tagColor(for:dark:)`、`FileLog.write(_:)`、`HoverIconButton`

- [ ] **Step 1: 提升共享原语访问级别**

`SelectionToolbarHelper.swift` 中，仅删掉以下声明前的 `private`（实现不动）：`func makePanelBackground`（110）、`enum FileLog`（148）、`func hexString`（189）、`func lucideImage`（194）、`func tagColor`（210）、`func lucideMarkup`（219）、`final class KeyablePanel`（697）、`final class HoverIconButton`（703）。`ToolbarButton`/`ToolbarDragHandle`/`HorizontalOnlyClip` 等保持 private（launcher 不用）。

- [ ] **Step 2: build.rs 双文件编译**

`swiftc` 参数中 `"native/SelectionToolbarHelper.swift",` 后插入 `"native/LauncherPanel.swift",`；文件末尾追加：

```rust
    println!("cargo:rerun-if-changed=native/LauncherPanel.swift");
```

- [ ] **Step 3: 创建 LauncherPanel.swift 外壳**

内容（完整可编译；Task 4/5 在此文件上追加）：

```swift
import AppKit

/// Launcher panel — double-Shift surface for jumping to tagged folders,
/// recent folders and running apps.
///
/// Top-level isolated from the toolbar/result-card/notes flows: it owns its
/// panel, data and actions. Shared bottom layers only: `KeyablePanel`,
/// `makePanelBackground`, `CardTheme`, `lucideImage`, `tagColor`, `FileLog`
/// (SelectionToolbarHelper.swift) and the TCP dispatch in
/// `SelectionToolbarApp.handleRequestData`.
final class LauncherPanelController: NSObject, NSWindowDelegate {
    /// Fired whenever the panel hides itself (Esc / focus loss); the app
    /// controller wires this to its action channel ("launcher-hidden").
    var onHidden: (() -> Void)?

    private static let panelWidth: CGFloat = 520
    private static let rowHeight: CGFloat = 34
    private static let headerHeight: CGFloat = 26
    private static let maxListHeight: CGFloat = 11 * LauncherPanelController.rowHeight
    private static let chromeHeight: CGFloat = 88 // search 12+26+8 + tabs 24+8 + bottom pad 10
    private static let recentsKey = "launcher.recents"

    private let panel: KeyablePanel
    private let root: FlippedView
    private let searchField = NSSearchField()
    private let foldersTabButton = NSButton()
    private let appsTabButton = NSButton()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var cardTheme: CardTheme = .dark

    enum Tab { case folders, apps }
    var tab: Tab = .folders {
        didSet { guard tab != oldValue else { return }; syncTabButtons(); reload() }
    }

    enum Row {
        case header(String)
        case folder(FolderItem)
        case recent(RecentItem)
        case app(RunningAppItem)
    }

    struct FolderItem { let path: String; let name: String; let tag: String }
    struct RecentItem: Codable, Equatable { var path: String; var count: Int; var lastAt: Double }
    struct RunningAppItem { let app: NSRunningApplication; let name: String }

    var rows: [Row] = []

    private var filterText: String {
        searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
    }

    override init() {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let (background, content, _) = makePanelBackground(
            frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 240),
            cornerRadius: 14
        )
        panel.contentView = background
        root = FlippedView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 240))
        content.addSubview(root)
        super.init()
        panel.delegate = self
        buildChrome()
        applyTheme(dark: true)
    }

    // MARK: show / hide

    func show() {
        reload()
        placePanel()
        searchField.stringValue = ""
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func hide(notify: Bool) {
        panel.orderOut(nil)
        if notify { onHidden?() }
    }

    func windowDidResignKey(_ notification: Notification) {
        hide(notify: true)
    }

    func applyTheme(dark: Bool) {
        cardTheme = dark ? .dark : .light
        panel.appearance = dark
            ? NSAppearance(named: .vibrantDark)
            : NSAppearance(named: .vibrantLight)
        styleChrome()
        tableView.reloadData()
    }

    // MARK: chrome

    private func buildChrome() {
        let side: CGFloat = 12

        searchField.frame = NSRect(x: side, y: 12, width: Self.panelWidth - side * 2, height: 26)
        searchField.placeholderString = "Search"
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        searchField.sendsActionOnEndEditing = false
        searchField.wantsLayer = true
        root.addSubview(searchField)

        for (button, title) in [(foldersTabButton, "Folders"), (appsTabButton, "Apps")] {
            button.title = title
            button.font = .systemFont(ofSize: 12, weight: .medium)
            button.bezelStyle = .recessed
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.target = self
            root.addSubview(button)
        }
        foldersTabButton.action = #selector(tabClicked(_:))
        appsTabButton.action = #selector(tabClicked(_:))
        foldersTabButton.tag = 0
        appsTabButton.tag = 1

        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = Self.rowHeight
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.backgroundColor = .clear
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("LauncherColumn"))
        tableView.addTableColumn(column)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        root.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        root.addSubview(emptyLabel)

        syncTabButtons()
    }

    @objc private func tabClicked(_ sender: NSButton) {
        tab = sender.tag == 0 ? .folders : .apps
    }

    private func syncTabButtons() {
        foldersTabButton.layer?.backgroundColor = (tab == .folders
            ? cardTheme.selectedFill
            : cardTheme.hoverFill).cgColor
        appsTabButton.layer?.backgroundColor = (tab == .apps
            ? cardTheme.selectedFill
            : cardTheme.hoverFill).cgColor
        foldersTabButton.contentTintColor = cardTheme.foreground
        appsTabButton.contentTintColor = cardTheme.foreground
    }

    private func styleChrome() {
        searchField.layer?.backgroundColor = cardTheme.inputFill.cgColor
        searchField.layer?.borderColor = cardTheme.hairline.cgColor
        searchField.layer?.borderWidth = 0.5
        emptyLabel.textColor = cardTheme.tertiaryText
        syncTabButtons()
    }

    private func layoutChrome(height: CGFloat) {
        let side: CGFloat = 12
        var x = side
        for button in [foldersTabButton, appsTabButton] {
            button.sizeToFit()
            button.frame = NSRect(x: x, y: 46, width: max(button.fittingSize.width + 20, 64), height: 24)
            x = button.frame.maxX + 6
        }
        scrollView.frame = NSRect(x: 0, y: 78, width: Self.panelWidth, height: height - Self.chromeHeight)
        emptyLabel.frame = NSRect(x: side, y: 78, width: Self.panelWidth - side * 2, height: 40)
    }

    /// Top-anchored adaptive height: list area is capped, panel never exceeds
    /// ~480pt total, minimum ~200pt.
    private var panelHeight: CGFloat {
        let listHeight = min(rows.reduce(0.0) { $0 + rowHeight(for: $1) }, Self.maxListHeight)
        return min(max(Self.chromeHeight + max(listHeight, Self.rowHeight * 3), 200), 480)
    }

    private func rowHeight(for row: Row) -> CGFloat {
        if case .header = row { return Self.headerHeight }
        return Self.rowHeight
    }

    private func placePanel() {
        let size = NSSize(width: Self.panelWidth, height: panelHeight)
        root.frame = NSRect(origin: .zero, size: size)
        layoutChrome(height: size.height)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = visible.midX - size.width / 2
        let y = max(visible.maxY - visible.height * 0.25 - size.height, visible.minY)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    // MARK: data (empty shell — Task 4/5 fill in)

    func reload() {
        rows = []
        tableView.reloadData()
        emptyLabel.isHidden = false
        emptyLabel.stringValue = "No tagged folders — tag folders in Finder to list them here"
        placePanel()
    }
}

/// Top-down layout container (row 0 = the top edge).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
```

- [ ] **Step 4: helper 集成（SelectionToolbarHelper.swift 三处接缝）**

4a. `SelectionToolbarApp` 属性区（`private var notesPanel: NSPanel!` 附近）新增：

```swift
    private lazy var launcherController: LauncherPanelController = {
        let controller = LauncherPanelController()
        controller.onHidden = { [weak self] in
            self?.postAction(action: "launcher-hidden", text: "-")
        }
        return controller
    }()
```

4b. `handleRequestData`（2603）内，`POST /notes-hide` 分支之后插入：

```swift
        if request.hasPrefix("POST /launcher-show ") {
            DispatchQueue.main.async {
                self.launcherController.show()
            }
            return
        }

        if request.hasPrefix("POST /launcher-hide ") {
            DispatchQueue.main.async {
                self.launcherController.hide(notify: false)
            }
            return
        }
```

4c. `applyTheme`（2750）末尾 `log("theme applied ...")` 之前插入：

```swift
        launcherController.applyTheme(dark: theme == .dark)
```

- [ ] **Step 5: 编译 + 手动验证面板外壳**

Run: `cargo build --manifest-path src-tauri/Cargo.toml`（触发 build.rs swiftc；两文件编译）
Expected: 成功。若 swiftc 报错，按错误修正后重跑。

启动 app 验证（手动 smoke）：

```bash
npm run tauri dev          # 后台起 dev；等主窗口出现
grep "toolbarPort" /tmp/lexi-selection-helper.log | tail -1   # 记下端口 N
curl -X POST "http://127.0.0.1:N/launcher-show"
```

Expected: 鼠标所在屏幕中上部出现空 launcher 面板（搜索框 + Folders/Apps 两个 pill + 空态文案）；点击面板外或按 Esc 无 crash（Esc 路由在 Task 5，外壳阶段点击外部即 resignKey 隐藏）；`/tmp/lexi-selection-helper.log` 无异常。

- [ ] **Step 6: Commit**

```bash
git add src-tauri/native/LauncherPanel.swift src-tauri/native/SelectionToolbarHelper.swift src-tauri/build.rs
git commit -m "feat(launcher): helper shell — glass panel chrome, tab pills, /launcher-show|hide dispatch, theme hookup"
```

---

### Task 4: Swift — 文件夹页（标签查询、Recent、打开动作）

**Files:**
- Modify: `src-tauri/native/LauncherPanel.swift`（在 `LauncherPanelController` 内追加数据成员与方法；文件末尾追加 cell 类）

**Interfaces:**
- Consumes: Task 3 的外壳（`rows`/`reload()`/`cardTheme`/`tableView`）；`tagColor(for:dark:)`、`lucideImage(for:title:color:)`、`HoverIconButton`。
- Produces（Task 5 与本文件内依赖）:
  - `var taggedFolders: [FolderItem]`、`var recents: [RecentItem]`、`private var openFailures: [String: Int]`
  - `func buildFolderRows() -> [Row]`、`func refreshFoldersData()`、`func openPath(_ path: String, target: OpenTarget)`
  - `enum OpenTarget { case finder, editor, terminal }`、`private static let editorBundleIds`
  - `func numberOfRows(in:) -> Int` / `func tableView(_:viewFor:row:) -> NSView?` / `func tableView(_:rowViewForRow:) -> NSTableRowView?` / `func tableView(_:heightOfRow:) -> CGFloat`（dataSource/delegate 协议声明加到类声明）
  - cell 类：`LauncherHeaderCell`、`LauncherFolderCell`、`LauncherRowView`

- [ ] **Step 1: 类声明加协议**

`final class LauncherPanelController: NSObject, NSWindowDelegate` 改为：

```swift
final class LauncherPanelController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate
```

- [ ] **Step 2: 追加数据成员（`var rows` 声明之后）**

```swift
    // folders data
    private var taggedFolders: [FolderItem] = []
    private var recents: [RecentItem] = LauncherPanelController.loadRecents()
    private var openFailures: [String: Int] = [:]
    private var metadataQuery: NSMetadataQuery?
    private var lastQueryAt: Date?
    private var editorAppURL: URL?

    enum OpenTarget { case finder, editor, terminal }

    /// First installed editor wins (spec §4.4).
    private static let editorBundleIds = ["com.microsoft.VSCode", "dev.zed.Zed", "com.sublimetext.4"]
```

- [ ] **Step 3: 替换外壳的 `reload()` 并追加行构建**

将 Task 3 的 `reload()` 替换为：

```swift
    func reload() {
        refreshFoldersData()
        switch tab {
        case .folders: rows = buildFolderRows()
        case .apps: rows = [] // apps tab lands in Task 5
        }
        editorAppURL = Self.editorBundleIds.lazy.compactMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }.first
        tableView.reloadData()
        let selectable = selectableRowIndexes()
        if let first = selectable.first {
            tableView.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        }
        let empty = rows.isEmpty
        emptyLabel.isHidden = !empty
        emptyLabel.stringValue = tab == .folders
            ? "No tagged folders — tag folders in Finder to list them here"
            : "No matching apps"
        placePanel()
    }

    private func selectableRowIndexes() -> [Int] {
        rows.indices.filter { row in
            if case .header = rows[row] { return false }
            return true
        }
    }

    private func buildFolderRows() -> [Row] {
        let filter = filterText
        var out: [Row] = []
        let matching = taggedFolders.filter { item in
            filter.isEmpty
                || item.name.lowercased().contains(filter)
                || item.path.lowercased().contains(filter)
        }
        let grouped = Dictionary(grouping: matching) { $0.tag.isEmpty ? "Untagged" : $0.tag }
        for tag in grouped.keys.sorted() {
            out.append(.header(tag))
            out += grouped[tag]!
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
                .map { .folder($0) }
        }
        let recentMatches = recents.filter { item in
            filter.isEmpty
                || item.path.lowercased().contains(filter)
                || URL(fileURLWithPath: item.path).lastPathComponent.lowercased().contains(filter)
        }
        if !recentMatches.isEmpty {
            out.append(.header("Recent"))
            out += recentMatches.map { .recent($0) }
        }
        return out
    }
```

- [ ] **Step 4: 追加标签查询与 recents（`buildFolderRows` 之后）**

```swift
    // MARK: tagged folders (Spotlight metadata)

    private func refreshFoldersData() {
        if let last = lastQueryAt, Date().timeIntervalSince(last) < 5 { return }
        stopMetadataQuery()
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemUserTags == '*'")
        query.searchScopes = [NSHomeDirectory()]
        NotificationCenter.default.addObserver(
            self, selector: #selector(metadataQueryDidFinish(_:)),
            name: .NSMetadataQueryDidFinishGathering, object: query
        )
        query.start()
        metadataQuery = query
        lastQueryAt = Date()
    }

    private func stopMetadataQuery() {
        if let query = metadataQuery {
            NotificationCenter.default.removeObserver(self, object: query)
            query.stop()
        }
        metadataQuery = nil
    }

    @objc private func metadataQueryDidFinish(_ notification: Notification) {
        guard let query = notification.object as? NSMetadataQuery else { return }
        query.disableUpdates()
        var items: [FolderItem] = []
        for result in query.results {
            guard let item = result as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
            else { continue }
            let url = URL(fileURLWithPath: path)
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let rawTags = (item.value(forAttribute: "kMDItemUserTags") as? [String]) ?? []
            let tag = rawTags.map(Self.normalizedTag).first ?? ""
            items.append(FolderItem(path: path, name: url.lastPathComponent, tag: tag))
        }
        query.enableUpdates()
        stopMetadataQuery()
        taggedFolders = items.sorted {
            ($0.tag, $0.name.lowercased()) < ($1.tag, $1.name.lowercased())
        }
        if panel.isVisible && tab == .folders { reload() }
    }

    /// Finder writes the 7 default color tags with a leading symbol scalar
    /// (e.g. "🔴红色") — strip leading symbol/emoji scalars, keep the name.
    static func normalizedTag(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.drop { scalar in
            scalar.value >= 0x1F000 || (scalar.value >= 0x2190 && scalar.value <= 0x2BFF)
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: recents (helper-local persistence)

    private static func loadRecents() -> [RecentItem] {
        guard let data = UserDefaults.standard.data(forKey: recentsKey),
              let items = try? JSONDecoder().decode([RecentItem].self, from: data)
        else { return [] }
        return items.sorted { $0.lastAt > $1.lastAt }
    }

    private func persistRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: Self.recentsKey)
        }
    }

    /// Record an open attempt. A failing path is not re-inserted; after 3
    /// failures the entry is dropped entirely (spec §7).
    private func recordOpen(path: String, ok: Bool) {
        let previous = recents.first { $0.path == path }
        recents.removeAll { $0.path == path }
        if ok {
            recents.insert(
                RecentItem(path: path, count: (previous?.count ?? 0) + 1, lastAt: Date().timeIntervalSince1970),
                at: 0
            )
            openFailures[path] = nil
        } else {
            let failures = (openFailures[path] ?? 0) + 1
            if failures >= 3 {
                openFailures[path] = nil
            } else {
                openFailures[path] = failures
            }
        }
        if recents.count > 10 { recents = Array(recents.prefix(10)) }
        persistRecents()
    }
```

- [ ] **Step 5: 追加打开动作（`recordOpen` 之后）**

```swift
    // MARK: open actions

    private func openPath(_ path: String, target: OpenTarget) {
        guard FileManager.default.fileExists(atPath: path) else {
            recordOpen(path: path, ok: false)
            if panel.isVisible && tab == .folders { reload() }
            return
        }
        let url = URL(fileURLWithPath: path)
        switch target {
        case .finder:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        case .editor:
            if let editor = editorAppURL {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: config)
            } else {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            }
        case .terminal:
            if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: config)
            }
        }
        recordOpen(path: path, ok: true)
        hide(notify: false)
    }
```

- [ ] **Step 6: 追加 table dataSource/delegate（`openPath` 之后）**

```swift
    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return Self.rowHeight }
        return rowHeight(for: rows[row])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .header(let title):
            let cell = reuse(LauncherHeaderCell.self, row: row)
            cell.configure(title: title, theme: cardTheme)
            return cell
        case .folder(let item):
            let cell = reuse(LauncherFolderCell.self, row: row)
            cell.configure(
                item: item,
                theme: cardTheme,
                showsEditor: editorAppURL != nil,
                missing: !FileManager.default.fileExists(atPath: item.path)
            ) { [weak self] action in
                guard let self else { return }
                switch action {
                case .row: self.openPath(item.path, target: .finder)
                case .editor: self.openPath(item.path, target: .editor)
                case .terminal: self.openPath(item.path, target: .terminal)
                }
            }
            return cell
        case .recent(let item):
            let cell = reuse(LauncherFolderCell.self, row: row)
            cell.configure(
                item: FolderItem(path: item.path, name: URL(fileURLWithPath: item.path).lastPathComponent, tag: ""),
                theme: cardTheme,
                showsEditor: editorAppURL != nil,
                missing: !FileManager.default.fileExists(atPath: item.path)
            ) { [weak self] action in
                guard let self else { return }
                switch action {
                case .row: self.openPath(item.path, target: .finder)
                case .editor: self.openPath(item.path, target: .editor)
                case .terminal: self.openPath(item.path, target: .terminal)
                }
            }
            return cell
        case .app(let item):
            return nil // app cells land in Task 5
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = tableView.makeView(
            withIdentifier: NSUserInterfaceItemIdentifier("LauncherRowView"),
            owner: self
        ) as? LauncherRowView ?? LauncherRowView()
        view.identifier = NSUserInterfaceItemIdentifier("LauncherRowView")
        view.fillColor = cardTheme.selectedFill
        return view
    }

    private func reuse<T: NSView>(_ type: T.Type, row: Int) -> T {
        let identifier = NSUserInterfaceItemIdentifier(String(describing: type))
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? T {
            return reused
        }
        let view = T(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: rowHeight(for: rows[row])))
        view.identifier = identifier
        return view
    }
```

- [ ] **Step 7: 文件末尾追加 cell/row 类**

```swift
/// Section header row (tag name / "Recent").
final class LauncherHeaderCell: NSView {
    private let label = NSTextField(labelWithString: "")
    private var didLayout = false

    func configure(title: String, theme: CardTheme) {
        label.stringValue = title.uppercased()
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = theme.tertiaryText
        if !didLayout {
            didLayout = true
            label.frame = NSRect(x: 16, y: 6, width: 480, height: 14)
            addSubview(label)
        }
    }
}

/// Folder / recent row: tag dot, name, parent path, editor + terminal buttons.
final class LauncherFolderCell: NSView {
    enum Action { case row, editor, terminal }

    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let editorButton = HoverIconButton(frame: .zero)
    private let terminalButton = HoverIconButton(frame: .zero)
    private var onAction: ((Action) -> Void)?
    private var hoverArea: NSTrackingArea?
    private var didLayout = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseDown(with event: NSEvent) { onAction?(.row) }

    func configure(
        item: LauncherPanelController.FolderItem,
        theme: CardTheme,
        showsEditor: Bool,
        missing: Bool,
        _ handler: @escaping (Action) -> Void
    ) {
        onAction = handler
        alphaValue = missing ? 0.45 : 1.0
        if !didLayout {
            didLayout = true
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.frame = NSRect(x: 16, y: 14, width: 6, height: 6)
            addSubview(dot)

            nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
            nameLabel.frame = NSRect(x: 30, y: 8, width: 320, height: 16)
            addSubview(nameLabel)

            pathLabel.font = .systemFont(ofSize: 11)
            pathLabel.frame = NSRect(x: 30, y: 3, width: 320, height: 12)
            addSubview(pathLabel)

            terminalButton.frame = NSRect(x: 448, y: 6, width: 22, height: 22)
            terminalButton.toolTip = "Open in Terminal"
            addSubview(terminalButton)

            editorButton.frame = NSRect(x: 474, y: 6, width: 22, height: 22)
            editorButton.toolTip = "Open in Editor"
            addSubview(editorButton)
        }
        nameLabel.stringValue = item.name
        let parent = (item.path as NSString).deletingLastPathComponent
        pathLabel.stringValue = parent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        dot.layer?.backgroundColor = item.tag.isEmpty
            ? NSColor.clear.cgColor
            : tagColor(for: item.tag, dark: theme.isDark).cgColor
        dot.isHidden = item.tag.isEmpty
        nameLabel.textColor = theme.foreground
        pathLabel.textColor = theme.tertiaryText

        editorButton.isHidden = !showsEditor
        if let editorImage = lucideImage(for: "code", title: "Editor", color: theme.secondaryText) {
            editorButton.image = editorImage
        }
        if let terminalImage = lucideImage(for: "terminal", title: "Terminal", color: theme.secondaryText) {
            terminalButton.image = terminalImage
        }
        editorButton.target = self
        editorButton.action = #selector(editorClicked)
        terminalButton.target = self
        terminalButton.action = #selector(terminalClicked)
    }

    @objc private func editorClicked() { onAction?(.editor) }
    @objc private func terminalClicked() { onAction?(.terminal) }
}

/// Selection capsule row view (selectedFill on activation).
final class LauncherRowView: NSTableRowView {
    var fillColor: NSColor = .clear

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        fillColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 2), xRadius: 7, yRadius: 7).fill()
    }
}
```

说明：`editorButton`/`terminalButton` 用共享 `HoverIconButton`（NSButton 子类，hover 填充自绘）——通过其原生 `target/action` 接线，无需改动共享类。

- [ ] **Step 8: 编译 + 手动验证文件夹页**

Run: `cargo build --manifest-path src-tauri/Cargo.toml`
Expected: 编译成功。

手动：Finder 给 2 个文件夹打不同标签 → `curl -X POST "http://127.0.0.1:N/launcher-show"`（或直接**双击 Shift**，Task 2 已生效）→ 面板按标签分组显示、色点正确；点击行/Enter 后的 Finder 打开在 Task 5 键盘就绪前可先验证鼠标点击（行点击 = Finder 打开）；编辑器/终端按钮按探测结果显隐；打开过的目录出现在 Recent；`defaults read com.lexi.selection-helper launcher.recents` 可见记录。

- [ ] **Step 9: Commit**

```bash
git add src-tauri/native/LauncherPanel.swift src-tauri/native/SelectionToolbarHelper.swift
git commit -m "feat(launcher): folders tab — finder-tag query via NSMetadataQuery, recents persistence, finder/editor/terminal actions"
```

---

### Task 5: Swift — 应用页 + 键盘交互（↑↓/Enter/Tab/Esc + 过滤）

**Files:**
- Modify: `src-tauri/native/LauncherPanel.swift`

**Interfaces:**
- Consumes: Task 4 的 `rows`/`reload()`/`selectableRowIndexes()`/`openPath`/cell 体系。
- Produces: `func buildAppRows() -> [Row]`、`private func activateApp(_ item: RunningAppItem)`、键盘 `moveSelection(_:)/activateSelected()/activateRow(_:)`、`LauncherAppCell`、`control(_:textView:doCommandBy:)`。

- [ ] **Step 1: reload() 的 apps 分支接真数据**

Task 4 中 `case .apps: rows = []` 替换为：

```swift
        case .apps: rows = buildAppRows()
```

- [ ] **Step 2: 追加应用页数据与激活（`openPath` 之后）**

```swift
    // MARK: running apps

    private func buildAppRows() -> [Row] {
        let filter = filterText
        let own = ProcessInfo.processInfo.processIdentifier
        var apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular
                && app.bundleIdentifier != nil
                && app.processIdentifier != own
                && (filter.isEmpty
                    || (app.localizedName ?? "").lowercased().contains(filter))
        }
        let front = apps.first { $0.isActive }
        apps.removeAll { $0 == front }
        apps.sort { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        if let front { apps.insert(front, at: 0) }
        return apps.map { RunningAppItem(app: $0, name: $0.localizedName ?? $0.bundleIdentifier ?? "?") }
            .map { Row.app($0) }
    }

    private func activateApp(_ item: RunningAppItem) {
        if #available(macOS 14.0, *) {
            _ = item.app.activate()
        } else {
            _ = item.app.activate(options: [.activateIgnoringOtherApps])
        }
        hide(notify: false)
    }

    private func activateRow(_ index: Int) {
        guard index >= 0, index < rows.count else { return }
        switch rows[index] {
        case .folder(let item): openPath(item.path, target: .finder)
        case .recent(let item): openPath(item.path, target: .finder)
        case .app(let item): activateApp(item)
        case .header: break
        }
    }
```

- [ ] **Step 3: `tableView(_:viewFor:row:)` 的 `.app` 分支接真 cell**

```swift
        case .app(let item):
            let cell = reuse(LauncherAppCell.self, row: row)
            cell.configure(item: item, theme: cardTheme) { [weak self] in
                self?.activateApp(item)
            }
            return cell
```

- [ ] **Step 4: 键盘导航（`activateRow` 之后追加；搜索框为常驻 first responder）**

```swift
    // MARK: keyboard

    private func moveSelection(_ delta: Int) {
        let selectable = selectableRowIndexes()
        guard !selectable.isEmpty else { return }
        let next: Int
        if let current = selectable.firstIndex(of: tableView.selectedRow) {
            let target = current + delta
            next = selectable[min(max(target, 0), selectable.count - 1)]
        } else {
            next = delta > 0 ? selectable[0] : selectable[selectable.count - 1]
        }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func activateSelected() {
        let row = tableView.selectedRow
        if row >= 0, row < rows.count {
            activateRow(row)
        } else if let first = selectableRowIndexes().first {
            activateRow(first)
        }
    }

    // NSSearchFieldDelegate — arrows/table/Enter/Tab/Esc while the search
    // field holds first responder.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case NSSelectorFromString("moveUp:"):
            moveSelection(-1)
            return true
        case NSSelectorFromString("moveDown:"):
            moveSelection(1)
            return true
        case NSSelectorFromString("insertNewline:"):
            activateSelected()
            return true
        case NSSelectorFromString("insertTab:"):
            tab = tab == .folders ? .apps : .folders
            return true
        case NSSelectorFromString("cancelOperation:"):
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                reload()
            } else {
                hide(notify: true)
            }
            return true
        default:
            return false
        }
    }

    // NSSearchFieldDelegate — live filter.
    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        reload()
    }
```

同时在 `buildChrome()` 中 `searchField` 配置区追加 `searchField.delegate = self`。

- [ ] **Step 5: 文件末尾追加 `LauncherAppCell`**

```swift
/// Running-app row: app icon + localized name.
final class LauncherAppCell: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private var onActivate: (() -> Void)?
    private var didLayout = false

    override func mouseDown(with event: NSEvent) { onActivate?() }

    func configure(
        item: LauncherPanelController.RunningAppItem,
        theme: CardTheme,
        _ handler: @escaping () -> Void
    ) {
        onActivate = handler
        if !didLayout {
            didLayout = true
            iconView.frame = NSRect(x: 16, y: 7, width: 20, height: 20)
            addSubview(iconView)
            nameLabel.font = .systemFont(ofSize: 13)
            nameLabel.frame = NSRect(x: 46, y: 9, width: 440, height: 16)
            addSubview(nameLabel)
        }
        iconView.image = item.app.icon
        nameLabel.stringValue = item.name
        nameLabel.textColor = theme.foreground
    }
}
```

- [ ] **Step 6: 编译 + 手动验证键盘与应用页**

Run: `cargo build --manifest-path src-tauri/Cargo.toml`
Expected: 编译成功。

手动 smoke：
1. 双击 Shift → 面板出现，搜索框聚焦。
2. 快速输入 `Shift+H Shift+I`（打 "HI"）→ 面板**不**误弹。
3. Apps 页：frontmost App 在首位；`↑↓` 移动胶囊选中、`Enter` 切入目标 App、面板隐藏。
4. Folders 页：输入过滤词即时过滤；`Tab` 在两页间切换；`Esc` 先清搜索词、再按关闭。
5. 点击面板外任意处 → resignKey 关闭；`/tmp/lexi-native-toolbar.log` 出现 launcher-hidden 相关 action 日志（helper log 中）。

- [ ] **Step 7: Commit**

```bash
git add src-tauri/native/LauncherPanel.swift
git commit -m "feat(launcher): apps tab with frontmost-first ordering, keyboard navigation, tab switching, live filter"
```

---

### Task 6: 前端 — launcherShortcut 设置项

**Files:**
- Modify: `src/types.ts:53`（`popupShortcut: string;` 旁）
- Modify: `src/lib/defaults.ts:169`（`popupShortcut` 旁）
- Modify: `src/App.tsx:70-74`（settings 同步块）
- Modify: `src/pages/SettingsPage.tsx:213-221`（Popup 卡片）

**Interfaces:**
- Consumes: Task 2 的 `set_launcher_shortcut` 命令（参数 `shortcut: string`）。
- Produces: `AppSettings.launcherShortcut: string`（默认 `"Shift+Shift"`）；设置读写走既有 `loadSettings/saveSettings` 泛型合并（`database.ts:35-37` 对未知 string 键原样合并，无需改动 database.ts）。

- [ ] **Step 1: 类型与默认值**

`types.ts` `AppSettings` 中 `popupShortcut: string;` 之后加：

```ts
  launcherShortcut: string;
```

`defaults.ts` `DEFAULT_SETTINGS` 中 `popupShortcut: "Cmd+Shift+T",` 之后加：

```ts
  launcherShortcut: "Shift+Shift",
```

- [ ] **Step 2: App.tsx 启动同步**

`invoke("set_popup_shortcut", ...)` 块（70-74）之后追加：

```tsx
      void invoke("set_launcher_shortcut", {
        shortcut: settings.launcherShortcut,
      }).catch((error) => {
        console.warn("Failed to sync launcher shortcut", error);
      });
```

- [ ] **Step 3: SettingsPage 下拉**

Popup 卡片内（`ShortcutRecorder` 的 Field 之后）追加（`Select` 已从 `ui/Field` 导出，与文件现有 import 合并）：

```tsx
            <Field label="Show launcher shortcut" inline hint="Opens the launcher panel from any Space.">
              <Select
                value={draft.launcherShortcut}
                onChange={(event) => setDraft({ ...draft, launcherShortcut: event.target.value })}
              >
                <option value="Shift+Shift">Double Shift</option>
                <option value="Alt+Alt">Double Option</option>
                <option value="Cmd+Cmd">Double Command</option>
                <option value="Cmd+Shift+L">Cmd+Shift+L</option>
              </Select>
            </Field>
```

- [ ] **Step 4: 验证**

Run: `npm run tauri dev`
Expected: Settings → Popup 卡片出现「Show launcher shortcut」下拉；切到 `Double Option` 保存后（确认既有保存按钮/自动保存流程），**双击 Option** 唤起面板、双击 Shift 不再唤起；切回 `Double Shift` 恢复。重启 app 后选择保留（sqlite `settings.launcherShortcut`）。

- [ ] **Step 5: Commit**

```bash
git add src/types.ts src/lib/defaults.ts src/App.tsx src/pages/SettingsPage.tsx
git commit -m "feat(launcher): launcherShortcut setting with preset select"
```

---

### Task 7: 端到端 smoke + 回归

**Files:**
- 无代码改动（发现问题则修复并追加提交）

- [ ] **Step 1: 完整构建**

```bash
npm run tauri build
```
Expected: 成功产出 app bundle（helper 双文件编译、签名通过）。

- [ ] **Step 2: spec §8 清单全过**

1. Finder 给 2 个文件夹打不同标签 → 双击 Shift → 分组与色点正确。
2. 快速打 `HI`（`Shift+H Shift+I`）→ 不误触。
3. Folders 行 Enter/click → Finder 打开；编辑器/终端按钮各自生效（未装任何编辑器时编辑器按钮隐藏）。
4. 打开过的文件夹进入 Recent；重启 Lexi（helper 随之重启）后 Recent 仍在。
5. Apps 页 frontmost 置顶，点击切入。
6. Esc / 点击面板外 → 面板隐藏。
7. Settings 切换 preset → 立即生效。
8. **回归**：双击 Ctrl popup（含 Ctrl+Ctrl 配置）、Cmd+Shift+T、划词 toolbar、result card、Notes 面板行为全部不变。
9. `tail -f /tmp/lexi-native-toolbar.log` 观察 `launcher shortcut detected` / `launcher show` 日志无异常。

- [ ] **Step 3: 修复发现的问题并提交**

```bash
git add -A && git commit -m "fix(launcher): smoke-test fixes"
```

（无问题则跳过本步。）
