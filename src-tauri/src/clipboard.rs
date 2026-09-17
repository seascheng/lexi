//! Clipboard panel — Alt+V native clipboard history (capture → search →
//! paste-back), rendered by the selection helper's ClipboardPanel.swift.
//!
//! Top-level isolated subsystem, third panel beside ActionPanel and
//! LauncherPanel: this module owns hotkey state and TCP calls only.
//! Capture/store/UI live in the helper (Clipboard{Store,Monitor,Panel}.swift).
//! Reused bottom layers: the CGEventTap (native_toolbar), the helper TCP
//! transport (`post_to_helper`) and the `/theme` push pipeline.

use std::path::Path;
use std::process::Command;
use std::sync::{LazyLock, Mutex};
use std::time::Instant;

use core_graphics::event::CGEvent;
use tauri::{AppHandle, Manager};

use crate::native_toolbar::{
    detect_double_press, log_native, modifier_flag, post_to_helper, shortcut_matches_keydown,
    toolbar_port, ShortcutMode,
};

const DEFAULT_CLIPBOARD_SHORTCUT: &str = "Alt+V";

static CLIPBOARD_SHORTCUT: LazyLock<Mutex<ShortcutMode>> =
    LazyLock::new(|| Mutex::new(default_clipboard_shortcut()));
/// Last press of the clipboard's double-modifier shortcut (see
/// `detect_double_press` for the typing guard). Unused by the Alt+V combo
/// default — only DoubleModifier presets reach it.
static LAST_CLIPBOARD_PRESS: Mutex<Option<Instant>> = Mutex::new(None);

fn default_clipboard_shortcut() -> ShortcutMode {
    ShortcutMode::parse(DEFAULT_CLIPBOARD_SHORTCUT).expect("default clipboard shortcut parses")
}

fn current_clipboard_shortcut() -> ShortcutMode {
    CLIPBOARD_SHORTCUT
        .lock()
        .map(|mode| *mode)
        .unwrap_or_else(|_| default_clipboard_shortcut())
}

/// Read once from sqlite at startup — same sqlite3-CLI pattern as the popup
/// and launcher shortcuts (the frontend also pushes the live value via the
/// command below).
pub(crate) fn initialize(app: &tauri::App) {
    let path = app
        .path()
        .app_data_dir()
        .ok()
        .map(|dir| dir.join("lexi.db"));
    let saved = path
        .as_deref()
        .and_then(read_clipboard_shortcut_from_sqlite)
        .unwrap_or_else(|| DEFAULT_CLIPBOARD_SHORTCUT.to_string());
    if let Some(mode) = ShortcutMode::parse(&saved) {
        if let Ok(mut current) = CLIPBOARD_SHORTCUT.lock() {
            *current = mode;
        }
    }
    log_native(&format!("clipboard shortcut initialized ({saved})"));
}

fn read_clipboard_shortcut_from_sqlite(path: &Path) -> Option<String> {
    let output = Command::new("sqlite3")
        .arg(path)
        .arg("SELECT value FROM settings WHERE key = 'clipboardShortcut' LIMIT 1;")
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
pub fn set_clipboard_shortcut(shortcut: String) -> Result<(), String> {
    let mode = ShortcutMode::parse(&shortcut)
        .ok_or_else(|| format!("Invalid shortcut format: {shortcut}"))?;
    let mut current = CLIPBOARD_SHORTCUT
        .lock()
        .map_err(|_| "clipboard shortcut state is unavailable".to_string())?;
    *current = mode;
    log_native(&format!("set clipboard shortcut={shortcut}"));
    Ok(())
}

/// FlagsChanged hook from the tap. Only consulted for DoubleModifier presets
/// ("Alt+Alt" / "Cmd+Cmd"); the Alt+V combo default matches on KeyDown.
pub(crate) fn handle_flags_changed(app: &AppHandle, event: &CGEvent) {
    let ShortcutMode::DoubleModifier { key_code } = current_clipboard_shortcut() else {
        return;
    };
    let pressed = modifier_flag(key_code)
        .map(|flag| event.get_flags().contains(flag))
        .unwrap_or(false);
    if !pressed {
        return; // only act on press, not release
    }
    if detect_double_press(&LAST_CLIPBOARD_PRESS) {
        log_native("double-modifier clipboard shortcut detected");
        let app = app.clone();
        std::thread::spawn(move || show_clipboard(&app));
    }
}

/// Combo-form clipboard shortcut (Alt+V default) matches on KeyDown.
pub(crate) fn is_clipboard_hotkey(event: &CGEvent) -> bool {
    is_clipboard_hotkey_with(&current_clipboard_shortcut(), event)
}

fn is_clipboard_hotkey_with(mode: &ShortcutMode, event: &CGEvent) -> bool {
    shortcut_matches_keydown(mode, event)
}

/// POST /clipboard-show — the helper's ClipboardPanelController treats this
/// as a toggle (visible → hide), so repeat presses close the panel.
/// Refreshes the notes snapshot first: the panel's tag tabs read the same
/// NOTES_SNAPSHOT feed the ActionPanel's notes list uses.
/// Runs on a worker thread (TCP write).
pub(crate) fn show_clipboard(app: &tauri::AppHandle) {
    let _ = crate::native_toolbar::send_card_notes(app);
    let Some(port) = toolbar_port() else {
        log_native("clipboard show skipped (helper port unknown)");
        return;
    };
    if let Err(error) = post_to_helper(port, "/clipboard-show", "{}") {
        log_native(&format!("clipboard show failed: {error}"));
    }
}

/// text_injection borrows the pasteboard, resume after it restores. The
/// helper skips any change up to the suspended count, so the injected text
/// never lands in history as a genuine user copy.
pub(crate) fn post_suspend(change_count: i64) {
    post_clipboard_json("/clipboard-suspend", change_count);
}

pub(crate) fn post_resume(change_count: i64) {
    post_clipboard_json("/clipboard-resume", change_count);
}

fn post_clipboard_json(endpoint: &str, change_count: i64) {
    let Some(port) = toolbar_port() else {
        return;
    };
    let body = format!(r#"{{"changeCount":{change_count}}}"#);
    if let Err(error) = post_to_helper(port, endpoint, &body) {
        log_native(&format!("clipboard {endpoint} failed: {error}"));
    }
}

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
