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
        .unwrap_or_else(|_| default_launcher_shortcut())
}

/// Read once from sqlite at startup — same sqlite3-CLI pattern as the popup
/// shortcut (the frontend also pushes the live value via the command below).
pub(crate) fn initialize(app: &tauri::AppHandle) {
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
