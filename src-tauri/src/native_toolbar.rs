use crate::cursor::{cursor_position, mouse_location, CursorPosition};
use core_foundation::base::{CFRelease, CFType, CFTypeRef, TCFType};
use core_foundation::runloop::CFRunLoop;
use core_foundation::string::{CFString, CFStringRef};
use core_graphics::event::{
    CGEvent, CGEventFlags, CGEventTap, CGEventTapLocation, CGEventTapOptions, CGEventTapPlacement,
    CGEventType, CallbackResult, EventField, KeyCode,
};
use core_graphics::display::CGDisplay;
use serde::{Deserialize, Serialize};
use std::env;
use std::fs::OpenOptions;
use std::io::{ErrorKind, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::ptr;
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::{Emitter, LogicalPosition, LogicalSize, Manager};

extern "C" {
    fn objc_getClass(name: *const i8) -> *const std::ffi::c_void;
    fn sel_registerName(str: *const i8) -> *const std::ffi::c_void;
    fn objc_msgSend(
        obj: *mut std::ffi::c_void,
        sel: *const std::ffi::c_void,
        ...
    ) -> *mut std::ffi::c_void;
}

/// Show the popup window in front of all other windows and make it key (for
/// focus-lost auto-hide), but without activating the application so the source
/// app retains key status and its text selections stay highlighted.
fn show_window_without_focus(window: &tauri::WebviewWindow) {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};

    let Ok(handle) = window.window_handle() else { return };
    let RawWindowHandle::AppKit(appkit) = handle.as_raw() else { return };

    unsafe {
        let ns_view = appkit.ns_view.as_ptr();
        let ns_window = objc_msgSend(
            ns_view,
            sel_registerName(b"window\0".as_ptr() as *const i8),
        );
        if ns_window.is_null() {
            return;
        }

        // Force window to front above all other apps' windows
        objc_msgSend(
            ns_window,
            sel_registerName(b"orderFrontRegardless\0".as_ptr() as *const i8),
        );

        // Make key so Tauri's onFocusChanged fires on focus loss (auto-hide).
        objc_msgSend(
            ns_window,
            sel_registerName(b"makeKeyWindow\0".as_ptr() as *const i8),
        );
    }
}

/// Disable WebKit's occlusion detection so rAF/animations keep running when the
/// window is hidden. Without this, WebKit throttles rendering for windows it
/// considers off-screen, causing blank frames on show (Raycast uses the same trick).
fn disable_occlusion_detection(window: &tauri::WebviewWindow) {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};

    let Ok(handle) = window.window_handle() else { return };
    let RawWindowHandle::AppKit(appkit) = handle.as_raw() else { return };

    unsafe {
        let ns_view = appkit.ns_view.as_ptr();
        let ns_window = objc_msgSend(
            ns_view,
            sel_registerName(b"window\0".as_ptr() as *const i8),
        );
        if ns_window.is_null() {
            return;
        }

        // Check if the class responds to setWindowOcclusionDetectionEnabled:
        let sel = sel_registerName(b"setWindowOcclusionDetectionEnabled:\0".as_ptr() as *const i8);
        let ns_window_class = objc_msgSend(
            ns_window,
            sel_registerName(b"class\0".as_ptr() as *const i8),
        );
        let responds: bool = !objc_msgSend(
            ns_window_class,
            sel_registerName(b"instancesRespondToSelector:\0".as_ptr() as *const i8),
            sel,
        ).is_null();

        if !responds {
            log_native("windowOcclusionDetectionEnabled not available on this macOS");
            return;
        }

        objc_msgSend(
            ns_window,
            sel,
            0 as std::ffi::c_int, // NO
        );
    }
}

/// Set NSWindow.collectionBehavior so the popup appears on ALL macOS Spaces/desktops.
/// Without this, the popup stays on the Space where it was created at app launch.
fn configure_window_all_spaces(window: &tauri::WebviewWindow) {
    use raw_window_handle::{HasWindowHandle, RawWindowHandle};

    let Ok(handle) = window.window_handle() else { return };
    let RawWindowHandle::AppKit(appkit) = handle.as_raw() else { return };

    unsafe {
        let ns_view = appkit.ns_view.as_ptr();

        // [ns_view window] -> NSWindow*
        let ns_window = objc_msgSend(
            ns_view,
            sel_registerName(b"window\0".as_ptr() as *const i8),
        );

        if ns_window.is_null() {
            return;
        }

        // NSWindowCollectionBehaviorCanJoinAllSpaces  = 1 << 0 = 1
        // NSWindowCollectionBehaviorStationary         = 1 << 7 = 128
        // NSWindowCollectionBehaviorFullScreenAuxiliary = 1 << 8 = 256
        let behavior: u64 = 1 | 128 | 256;
        objc_msgSend(
            ns_window,
            sel_registerName(b"setCollectionBehavior:\0".as_ptr() as *const i8),
            behavior,
        );
    }
}

const DEFAULT_POPUP_SIZE: f64 = 420.0;
const IPC_HOST: &str = "127.0.0.1";
const LOG_PATH: &str = "/tmp/lexi-native-toolbar.log";
const AX_ERROR_SUCCESS: i32 = 0;
/// Fixed port the Chrome extension POSTs selected text to. Hardcoded so the
/// extension doesn't have to discover a dynamic port. Collisions are unlikely
/// (nothing else commonly uses 47xxx range).
const EXTENSION_PORT: u16 = 47291;

type AXUIElementRef = *const std::ffi::c_void;

static TOOLBAR_PORT: OnceLock<Mutex<Option<u16>>> = OnceLock::new();
static TOOLBAR_ACTIONS: OnceLock<Mutex<Vec<ToolbarActionItem>>> = OnceLock::new();
static TOOLBAR_ENABLED: OnceLock<Mutex<bool>> = OnceLock::new();
static POPUP_SHORTCUT: OnceLock<Mutex<ShortcutMode>> = OnceLock::new();
static LAST_CTRL_PRESS: Mutex<Option<Instant>> = Mutex::new(None);
static HANDOFF_TARGET_APP: OnceLock<Mutex<String>> = OnceLock::new();
static EXCLUDED_TOOLBAR_APPS: OnceLock<Mutex<Vec<String>>> = OnceLock::new();
/// Last observed NSPasteboard.changeCount. Cmd+C detection compares against
/// this — only fires the toolbar when the count actually increases.
static LAST_PASTEBOARD_CHANGE_COUNT: OnceLock<Mutex<isize>> = OnceLock::new();

/// Text captured from the user's most recent Cmd+C, with the time it was
/// captured. Used as the browser fallback when Ctrl+Ctrl popup shortcut
/// fires but AX can't read the selection (Chrome/Safari/Edge).
/// Window is 5s — after that the record is considered stale.
static LAST_COPIED_TEXT: OnceLock<Mutex<Option<(String, Instant)>>> = OnceLock::new();

/// How long after a Cmd+C the captured text is still considered usable.
const COPIED_TEXT_FRESH_SECS: u64 = 5;

/// Parsed keyboard shortcut for showing the popup.
#[derive(Clone, Copy)]
enum ShortcutMode {
    /// Traditional modifier+key combo, e.g. Cmd+Shift+T
    KeyCombo {
        cmd: bool,
        shift: bool,
        ctrl: bool,
        alt: bool,
        key_code: u16,
    },
    /// Double-press a modifier key within a time window
    DoubleCtrl,
}

impl ShortcutMode {
    fn default_shortcut() -> Self {
        Self::KeyCombo {
            cmd: true,
            shift: true,
            ctrl: false,
            alt: false,
            key_code: KeyCode::ANSI_T as u16,
        }
    }

    fn parse(shortcut: &str) -> Option<Self> {
        let lower = shortcut.trim().to_lowercase();

        // Double-modifier patterns: "Ctrl+Ctrl", "Control+Control"
        if lower == "ctrl+ctrl" || lower == "control+control" {
            return Some(Self::DoubleCtrl);
        }

        let parts: Vec<&str> = shortcut.split('+').collect();
        if parts.len() < 2 {
            return None;
        }

        let mut config = KeyComboBuilder {
            cmd: false,
            shift: false,
            ctrl: false,
            alt: false,
        };

        for part in &parts[..parts.len() - 1] {
            match part.trim().to_lowercase().as_str() {
                "cmd" | "command" => config.cmd = true,
                "shift" => config.shift = true,
                "ctrl" | "control" => config.ctrl = true,
                "alt" | "option" => config.alt = true,
                _ => return None,
            }
        }

        // Require at least one modifier
        if !config.cmd && !config.shift && !config.ctrl && !config.alt {
            return None;
        }

        let key_code = key_name_to_code(parts.last()?.trim())?;
        Some(Self::KeyCombo {
            cmd: config.cmd,
            shift: config.shift,
            ctrl: config.ctrl,
            alt: config.alt,
            key_code,
        })
    }
}

struct KeyComboBuilder {
    cmd: bool,
    shift: bool,
    ctrl: bool,
    alt: bool,
}

fn key_name_to_code(name: &str) -> Option<u16> {
    Some(match name.to_lowercase().as_str() {
        "a" => KeyCode::ANSI_A,
        "b" => KeyCode::ANSI_B,
        "c" => KeyCode::ANSI_C,
        "d" => KeyCode::ANSI_D,
        "e" => KeyCode::ANSI_E,
        "f" => KeyCode::ANSI_F,
        "g" => KeyCode::ANSI_G,
        "h" => KeyCode::ANSI_H,
        "i" => KeyCode::ANSI_I,
        "j" => KeyCode::ANSI_J,
        "k" => KeyCode::ANSI_K,
        "l" => KeyCode::ANSI_L,
        "m" => KeyCode::ANSI_M,
        "n" => KeyCode::ANSI_N,
        "o" => KeyCode::ANSI_O,
        "p" => KeyCode::ANSI_P,
        "q" => KeyCode::ANSI_Q,
        "r" => KeyCode::ANSI_R,
        "s" => KeyCode::ANSI_S,
        "t" => KeyCode::ANSI_T,
        "u" => KeyCode::ANSI_U,
        "v" => KeyCode::ANSI_V,
        "w" => KeyCode::ANSI_W,
        "x" => KeyCode::ANSI_X,
        "y" => KeyCode::ANSI_Y,
        "z" => KeyCode::ANSI_Z,
        "0" => KeyCode::ANSI_0,
        "1" => KeyCode::ANSI_1,
        "2" => KeyCode::ANSI_2,
        "3" => KeyCode::ANSI_3,
        "4" => KeyCode::ANSI_4,
        "5" => KeyCode::ANSI_5,
        "6" => KeyCode::ANSI_6,
        "7" => KeyCode::ANSI_7,
        "8" => KeyCode::ANSI_8,
        "9" => KeyCode::ANSI_9,
        "space" => KeyCode::SPACE,
        "return" | "enter" => KeyCode::RETURN,
        "tab" => KeyCode::TAB,
        "escape" | "esc" => KeyCode::ESCAPE,
        "backspace" | "delete" => KeyCode::DELETE,
        "f1" => KeyCode::F1,
        "f2" => KeyCode::F2,
        "f3" => KeyCode::F3,
        "f4" => KeyCode::F4,
        "f5" => KeyCode::F5,
        "f6" => KeyCode::F6,
        "f7" => KeyCode::F7,
        "f8" => KeyCode::F8,
        "f9" => KeyCode::F9,
        "f10" => KeyCode::F10,
        "f11" => KeyCode::F11,
        "f12" => KeyCode::F12,
        "=" | "equal" => KeyCode::ANSI_EQUAL,
        "-" | "minus" => KeyCode::ANSI_MINUS,
        "[" | "leftbracket" => KeyCode::ANSI_LEFT_BRACKET,
        "]" | "rightbracket" => KeyCode::ANSI_RIGHT_BRACKET,
        "'" | "quote" => KeyCode::ANSI_QUOTE,
        ";" | "semicolon" => KeyCode::ANSI_SEMICOLON,
        "\\" | "backslash" => KeyCode::ANSI_BACKSLASH,
        "," | "comma" => KeyCode::ANSI_COMMA,
        "/" | "slash" => KeyCode::ANSI_SLASH,
        "." | "period" => KeyCode::ANSI_PERIOD,
        "`" | "grave" => KeyCode::ANSI_GRAVE,
        _ => return None,
    } as u16)
}

fn current_popup_shortcut() -> ShortcutMode {
    POPUP_SHORTCUT
        .get_or_init(|| Mutex::new(ShortcutMode::default_shortcut()))
        .lock()
        .map(|config| *config)
        .unwrap_or_else(|_| ShortcutMode::default_shortcut())
}

fn initialize_popup_shortcut(app: &tauri::App) {
    let path = app
        .path()
        .app_data_dir()
        .ok()
        .map(|dir| dir.join("lexi.db"));

    let shortcut = path
        .as_ref()
        .and_then(|p| read_popup_shortcut_from_sqlite(p))
        .unwrap_or_else(|| "Cmd+Shift+T".to_string());

    if let Some(mode) = ShortcutMode::parse(&shortcut) {
        // Block *+C shortcuts — conflicts with copy
        let is_blocked = matches!(mode, ShortcutMode::KeyCombo { key_code, shift: false, .. }
            if key_code == KeyCode::ANSI_C as u16);
        if is_blocked {
            log_native("initial popup shortcut rejected (conflicts with copy), falling back to default");
        } else if let Ok(mut current) = POPUP_SHORTCUT.get_or_init(|| Mutex::new(ShortcutMode::default_shortcut())).lock() {
            *current = mode;
            log_native(&format!("initial popup shortcut={shortcut}"));
        }
    }
}

fn initialize_pasteboard_change_count() {
    let current = unsafe { pasteboard_change_count() };
    if let Ok(mut cell) = LAST_PASTEBOARD_CHANGE_COUNT
        .get_or_init(|| Mutex::new(current))
        .lock()
    {
        *cell = current;
    }
    log_native(&format!("initial pasteboard changeCount={current}"));
}

fn read_popup_shortcut_from_sqlite(path: &Path) -> Option<String> {
    let output = Command::new("sqlite3")
        .arg(path)
        .arg("SELECT value FROM settings WHERE key = 'popupShortcut' LIMIT 1;")
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let value = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if value.is_empty() {
        return None;
    }

    Some(value)
}

#[derive(Clone, Serialize)]
struct AiRequestPayload {
    text: String,
    mode: &'static str,
    #[serde(rename = "featureId")]
    feature_id: String,
}

#[derive(Clone, Serialize)]
struct PopupShownPayload {
    mode: &'static str,
}

#[derive(Clone, Serialize)]
struct ToolbarShowPayload {
    text: String,
    x: i32,
    y: i32,
    pending: bool,
    actions: Vec<ToolbarActionItem>,
}

#[derive(Serialize)]
struct ToolbarThemePayload {
    theme: String,
}

#[derive(Clone, Deserialize, Serialize)]
pub struct ToolbarActionItem {
    pub id: String,
    pub title: String,
    pub icon: String,
}

#[derive(Deserialize)]
struct ToolbarActionRequest {
    action: String,
    text: String,
}

pub fn setup_native_toolbar(app: &tauri::App) -> anyhow::Result<()> {
    log_native("setup native toolbar");
    request_system_permissions();
    initialize_toolbar_enabled(app);
    initialize_popup_shortcut(app);
    initialize_pasteboard_change_count();

    // Configure popup to appear on all Spaces and disable occlusion detection
    // (must be on main thread for NSWindow access)
    if let Some(window) = app.get_webview_window("popup_card") {
        configure_window_all_spaces(&window);
        disable_occlusion_detection(&window);
    }
    if let Some(window) = app.get_webview_window("float_bar") {
        disable_occlusion_detection(&window);
    }

    let app_handle = app.handle().clone();
    let listener = TcpListener::bind((IPC_HOST, 0))?;
    let action_port = listener.local_addr()?.port();
    let toolbar_port = available_port()?;
    remember_toolbar_port(toolbar_port);
    log_native(&format!(
        "ports action={} toolbar={}",
        action_port, toolbar_port
    ));

    spawn_action_server(listener, app_handle.clone());
    launch_helper(app, action_port, toolbar_port)?;
    wait_for_helper(toolbar_port);
    spawn_selection_monitor(app_handle.clone(), toolbar_port);
    spawn_extension_server();
    Ok(())
}

fn initialize_toolbar_enabled(app: &tauri::App) {
    let enabled = saved_toolbar_enabled(app).unwrap_or(true);
    if let Ok(mut current) = TOOLBAR_ENABLED.get_or_init(|| Mutex::new(true)).lock() {
        *current = enabled;
    }
    log_native(&format!("initial toolbar enabled={enabled}"));
}

fn saved_toolbar_enabled(app: &tauri::App) -> Option<bool> {
    let path = app
        .path()
        .app_data_dir()
        .ok()
        .map(|dir| dir.join("lexi.db"))?;
    read_toolbar_enabled_from_sqlite(&path)
}

fn saved_toolbar_enabled_for_app(app: &tauri::AppHandle) -> Option<bool> {
    let path = app
        .path()
        .app_data_dir()
        .ok()
        .map(|dir| dir.join("lexi.db"))?;
    read_toolbar_enabled_from_sqlite(&path)
}

fn read_toolbar_enabled_from_sqlite(path: &Path) -> Option<bool> {
    let output = Command::new("sqlite3")
        .arg(path)
        .arg("SELECT value FROM settings WHERE key = 'toolbarEnabled' LIMIT 1;")
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    match String::from_utf8_lossy(&output.stdout).trim() {
        "true" | "1" => Some(true),
        "false" | "0" => Some(false),
        _ => None,
    }
}

#[tauri::command]
pub fn set_native_toolbar_theme(theme: String) -> Result<(), String> {
    let theme = if theme == "light" { "light" } else { "dark" };
    let port = TOOLBAR_PORT
        .get_or_init(|| Mutex::new(None))
        .lock()
        .ok()
        .and_then(|current| *current)
        .ok_or_else(|| "native toolbar port is not ready".to_string())?;
    let body = serde_json::to_string(&ToolbarThemePayload {
        theme: theme.to_string(),
    })
    .map_err(|error| format!("Could not serialize toolbar theme: {error}"))?;

    // Retry a few times — helper may still be launching
    for attempt in 0..5 {
        match post_to_helper(port, "/theme", &body) {
            Ok(()) => return Ok(()),
            Err(e) if attempt < 4 => {
                log_native(&format!("theme send attempt {} failed: {e}, retrying...", attempt + 1));
                std::thread::sleep(std::time::Duration::from_millis(500));
            }
            Err(e) => return Err(format!("Could not send toolbar theme: {e}")),
        }
    }
    Ok(())
}

#[tauri::command]
pub fn set_native_toolbar_actions(actions: Vec<ToolbarActionItem>) -> Result<(), String> {
    let mut current = TOOLBAR_ACTIONS
        .get_or_init(|| Mutex::new(default_toolbar_actions()))
        .lock()
        .map_err(|_| "native toolbar actions are unavailable".to_string())?;
    *current = normalized_toolbar_actions(actions);
    let should_hide = current.is_empty();
    log_native(&format!(
        "set toolbar actions count={} enabled={}",
        current.len(),
        native_toolbar_enabled()
    ));
    drop(current);

    if should_hide {
        let _ = hide_native_toolbar();
    }

    Ok(())
}

#[tauri::command]
pub fn set_native_toolbar_enabled(enabled: bool) -> Result<(), String> {
    let mut current = TOOLBAR_ENABLED
        .get_or_init(|| Mutex::new(true))
        .lock()
        .map_err(|_| "native toolbar enabled state is unavailable".to_string())?;
    *current = enabled;
    drop(current);
    log_native(&format!("set toolbar enabled={enabled}"));

    if !enabled {
        let _ = hide_native_toolbar();
    }

    Ok(())
}

#[tauri::command]
pub fn set_popup_shortcut(shortcut: String) -> Result<(), String> {
    let mode = ShortcutMode::parse(&shortcut)
        .ok_or_else(|| format!("Invalid shortcut format: {shortcut}"))?;

    // Block *+C shortcuts (Cmd+C, Ctrl+C, etc.) — conflicts with copy.
    if let ShortcutMode::KeyCombo { key_code, shift: false, .. } = mode {
        if key_code == KeyCode::ANSI_C as u16 {
            return Err("Cannot use *+C as popup shortcut (conflicts with copy)".into());
        }
    }

    let mut current = POPUP_SHORTCUT
        .get_or_init(|| Mutex::new(ShortcutMode::default_shortcut()))
        .lock()
        .map_err(|_| "popup shortcut state is unavailable".to_string())?;
    *current = mode;
    log_native(&format!("set popup shortcut={shortcut}"));
    Ok(())
}

#[tauri::command]
pub fn configure_native_toolbar(
    enabled: bool,
    actions: Vec<ToolbarActionItem>,
) -> Result<(), String> {
    let normalized_actions = if enabled {
        normalized_toolbar_actions(actions)
    } else {
        Vec::new()
    };
    let action_count = normalized_actions.len();

    {
        let mut current_actions = TOOLBAR_ACTIONS
            .get_or_init(|| Mutex::new(default_toolbar_actions()))
            .lock()
            .map_err(|_| "native toolbar actions are unavailable".to_string())?;
        *current_actions = normalized_actions;
    }

    {
        let mut current_enabled = TOOLBAR_ENABLED
            .get_or_init(|| Mutex::new(true))
            .lock()
            .map_err(|_| "native toolbar enabled state is unavailable".to_string())?;
        *current_enabled = enabled;
    }

    log_native(&format!(
        "configure toolbar enabled={enabled} actions={action_count}"
    ));

    if !enabled || action_count == 0 {
        let _ = hide_native_toolbar();
    }

    Ok(())
}

#[tauri::command]
pub fn hide_native_toolbar() -> Result<(), String> {
    let port = TOOLBAR_PORT
        .get_or_init(|| Mutex::new(None))
        .lock()
        .map_err(|_| "toolbar port unavailable".to_string())?
        .ok_or_else(|| "toolbar port not set".to_string())?;

    post_to_helper(port, "/hide", "")
        .map_err(|error| format!("Could not hide toolbar: {error}"))
}

#[tauri::command]
pub fn set_excluded_toolbar_apps(apps: Vec<String>) -> Result<(), String> {
    let trimmed: Vec<String> = apps.into_iter().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
    if let Ok(mut current) = EXCLUDED_TOOLBAR_APPS.get_or_init(|| Mutex::new(vec!["com.apple.finder".to_string()])).lock() {
        *current = trimmed;
    }
    Ok(())
}

/// Get the bundle identifier of the frontmost (active) application.
fn frontmost_app_bundle_id() -> Option<String> {
    let output = Command::new("osascript")
        .arg("-e")
        .arg("id of app (path to frontmost application)")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let id = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if id.is_empty() { None } else { Some(id) }
}

fn remember_toolbar_port(port: u16) {
    if let Ok(mut current) = TOOLBAR_PORT.get_or_init(|| Mutex::new(None)).lock() {
        *current = Some(port);
    }
}

fn current_toolbar_actions() -> Vec<ToolbarActionItem> {
    TOOLBAR_ACTIONS
        .get_or_init(|| Mutex::new(default_toolbar_actions()))
        .lock()
        .map(|actions| actions.clone())
        .unwrap_or_else(|_| default_toolbar_actions())
}

fn native_toolbar_enabled() -> bool {
    TOOLBAR_ENABLED
        .get_or_init(|| Mutex::new(true))
        .lock()
        .map(|enabled| *enabled)
        .unwrap_or(true)
}

fn active_toolbar_actions() -> Option<Vec<ToolbarActionItem>> {
    if !native_toolbar_enabled() {
        return None;
    }

    let actions = current_toolbar_actions();
    (!actions.is_empty()).then_some(actions)
}

fn toolbar_enabled_for_app(app: &tauri::AppHandle) -> bool {
    let Some(enabled) = saved_toolbar_enabled_for_app(app) else {
        return native_toolbar_enabled();
    };

    if let Ok(mut current) = TOOLBAR_ENABLED.get_or_init(|| Mutex::new(true)).lock() {
        *current = enabled;
    }

    if !enabled {
        return false;
    }

    // Check if the frontmost app is in the exclusion list
    if let Some(bundle_id) = frontmost_app_bundle_id() {
        if let Ok(excluded) = EXCLUDED_TOOLBAR_APPS.get_or_init(|| Mutex::new(vec!["com.apple.finder".to_string()])).lock() {
            if excluded.iter().any(|ex| ex == &bundle_id) {
                log_native(&format!("toolbar excluded for app: {}", bundle_id));
                return false;
            }
        }
    }

    true
}

fn normalized_toolbar_actions(actions: Vec<ToolbarActionItem>) -> Vec<ToolbarActionItem> {
    let normalized = actions
        .into_iter()
        .filter_map(|action| {
            let id = action.id.trim();
            let title = action.title.trim();
            let icon = action.icon.trim();
            if id.is_empty() || title.is_empty() {
                return None;
            }

            Some(ToolbarActionItem {
                id: id.to_string(),
                title: title.to_string(),
                icon: if icon.is_empty() { "wand" } else { icon }.to_string(),
            })
        })
        .collect::<Vec<_>>();

    normalized
}

fn default_toolbar_actions() -> Vec<ToolbarActionItem> {
    vec![
        ToolbarActionItem {
            id: "translation".into(),
            title: "Translate".into(),
            icon: "languages".into(),
        },
        ToolbarActionItem {
            id: "copy".into(),
            title: "Copy".into(),
            icon: "clipboard".into(),
        },
        ToolbarActionItem {
            id: "search".into(),
            title: "Search".into(),
            icon: "search".into(),
        },
        ToolbarActionItem {
            id: "read".into(),
            title: "Read".into(),
            icon: "volume".into(),
        },
        ToolbarActionItem {
            id: "extract".into(),
            title: "Extract".into(),
            icon: "sparkles".into(),
        },
    ]
}

fn available_port() -> anyhow::Result<u16> {
    let listener = TcpListener::bind((IPC_HOST, 0))?;
    Ok(listener.local_addr()?.port())
}

fn spawn_action_server(listener: TcpListener, app: tauri::AppHandle) {
    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let app = app.clone();
            thread::spawn(move || handle_action_connection(stream, app));
        }
    });
}

/// Start the HTTP server the Chrome extension POSTs selected text to.
/// Bound to 127.0.0.1 only (no external exposure). Fixed port so the
/// extension can hardcode it — see EXTENSION_PORT.
fn spawn_extension_server() {
    thread::spawn(|| {
        let listener = match TcpListener::bind((IPC_HOST, EXTENSION_PORT)) {
            Ok(l) => {
                log_native(&format!(
                    "extension server listening on http://{IPC_HOST}:{EXTENSION_PORT}"
                ));
                l
            }
            Err(error) => {
                log_native(&format!(
                    "extension server bind failed on port {EXTENSION_PORT}: {error}"
                ));
                eprintln!(
                    "[toolbar] Could not bind extension server on port {EXTENSION_PORT}: {error}"
                );
                return;
            }
        };

        for stream in listener.incoming().flatten() {
            thread::spawn(|| handle_extension_connection(stream));
        }
    });
}

#[derive(Deserialize)]
struct ExtensionSelectionPayload {
    text: String,
}

fn handle_extension_connection(mut stream: TcpStream) {
    let buffer = match read_http_request(&mut stream) {
        Ok(buffer) => buffer,
        Err(error) => {
            let _ = write_response_with_cors(&mut stream, 400, &format!("read failed: {error}"));
            return;
        }
    };

    if buffer.is_empty() {
        return;
    }

    let request = String::from_utf8_lossy(&buffer);

    // CORS preflight — Chrome sends OPTIONS before any non-simple POST.
    if request.starts_with("OPTIONS ") {
        let _ = write_response_with_cors(&mut stream, 204, "");
        return;
    }

    if !request.starts_with("POST /selection ") {
        let _ = write_response_with_cors(&mut stream, 404, "not found");
        return;
    }

    let Some(body) = request.split("\r\n\r\n").nth(1) else {
        let _ = write_response_with_cors(&mut stream, 400, "missing body");
        return;
    };

    let payload: ExtensionSelectionPayload = match serde_json::from_str(body) {
        Ok(p) => p,
        Err(error) => {
            let _ = write_response_with_cors(&mut stream, 400, &format!("invalid json: {error}"));
            return;
        }
    };

    let text = payload.text.trim().to_string();
    if text.is_empty() {
        let _ = write_response_with_cors(&mut stream, 400, "empty text");
        return;
    }

    // 200 OK back to the extension ASAP — actual toolbar show happens off-thread.
    let _ = write_response_with_cors(&mut stream, 200, "ok");

    log_native(&format!("extension selection len={}", text.len()));

    thread::spawn(move || {
        // Respect the global toolbar enabled flag and action list. Skip if
        // disabled or no actions configured.
        if active_toolbar_actions().is_none() {
            log_native("extension: toolbar disabled or no actions, skipping");
            return;
        }

        let port = TOOLBAR_PORT
            .get_or_init(|| Mutex::new(None))
            .lock()
            .ok()
            .and_then(|cell| *cell);
        let Some(port) = port else {
            log_native("extension: toolbar port not set");
            return;
        };

        // Toolbar helper positions its NSPanel in Cocoa coordinates (origin at
        // the bottom-left of the primary display, y up), matching the AX path's
        // appkit_position_from_event. Use the live HID cursor location — NOT
        // cursor_position(), whose flipped (top-left origin) value is meant for
        // Tauri/tao window positioning and would land the toolbar off-screen.
        let position = mouse_location();
        show_toolbar(port, text, position, false);
    });
}

fn write_response_with_cors(stream: &mut TcpStream, status: u16, body: &str) -> std::io::Result<()> {
    let status_text = match status {
        200 | 204 => "OK",
        _ => "ERROR",
    };
    write!(
        stream,
        "HTTP/1.1 {status} {status_text}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}

fn handle_action_connection(mut stream: TcpStream, app: tauri::AppHandle) {
    let buffer = match read_http_request(&mut stream) {
        Ok(buffer) => buffer,
        Err(error) => {
            let _ = write_response(&mut stream, 400, &format!("read failed: {error}"));
            return;
        }
    };

    if buffer.is_empty() {
        return;
    }

    let request = String::from_utf8_lossy(&buffer);
    if !request.starts_with("POST /action ") {
        let _ = write_response(&mut stream, 404, "not found");
        return;
    }

    let Some(body) = request.split("\r\n\r\n").nth(1) else {
        let _ = write_response(&mut stream, 400, "missing body");
        return;
    };

    let action = match serde_json::from_str::<ToolbarActionRequest>(body) {
        Ok(action) => action,
        Err(error) => {
            let _ = write_response(&mut stream, 400, &format!("invalid json: {error}"));
            return;
        }
    };

    match dispatch_toolbar_action(&app, action) {
        Ok(()) => {
            let _ = write_response(&mut stream, 200, "ok");
        }
        Err(error) => {
            let _ = write_response(&mut stream, 500, &error);
        }
    }
}

struct ClickState {
    pre_selection: Option<String>,
    is_text_click: bool,
}

fn spawn_selection_monitor(app: tauri::AppHandle, toolbar_port: u16) {
    thread::spawn(move || {
        let click_state: Arc<Mutex<Option<ClickState>>> = Arc::new(Mutex::new(None));
        let events = vec![
            CGEventType::LeftMouseDown,
            CGEventType::LeftMouseUp,
            CGEventType::KeyDown,
            CGEventType::FlagsChanged,
        ];

        let result = CGEventTap::with_enabled(
            CGEventTapLocation::HID,
            CGEventTapPlacement::HeadInsertEventTap,
            CGEventTapOptions::ListenOnly,
            events,
            move |_proxy, event_type, event| {
                handle_system_event(&app, toolbar_port, &click_state, event_type, event);
                CallbackResult::Keep
            },
            CFRunLoop::run_current,
        );

        if result.is_err() {
            log_native("event tap install failed");
            eprintln!("Could not install Lexi system event tap. Grant Input Monitoring to Lexi.app and restart.");
            open_privacy_settings("Privacy_ListenEvent");
        } else {
            log_native("event tap stopped");
        }
    });
}

fn handle_system_event(
    app: &tauri::AppHandle,
    toolbar_port: u16,
    click_state: &Arc<Mutex<Option<ClickState>>>,
    event_type: CGEventType,
    event: &CGEvent,
) {
    match event_type {
        CGEventType::LeftMouseDown => {
            let loc = event.location();
            let snapshot = read_selected_text_via_ax()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty());
            let is_text_click = is_text_area_at_position(loc.x, loc.y);
            if let Ok(mut state) = click_state.lock() {
                *state = Some(ClickState {
                    pre_selection: snapshot,
                    is_text_click,
                });
            }
        }
        CGEventType::LeftMouseUp => {
            let state = click_state.lock().ok().and_then(|mut s| s.take());
            let Some(ClickState { pre_selection: pre, is_text_click, .. }) = state else {
                return;
            };

            if !is_text_click {
                return;
            }

            if !toolbar_enabled_for_app(app) {
                return;
            }

            if active_toolbar_actions().is_none() {
                return;
            }

            let position = appkit_position_from_event(event);
            thread::spawn(move || {
                // Delay to let the app process the mouse up and update its selection.
                // Our event tap runs BEFORE the app sees the event (HeadInsert),
                // so without this delay AXSelectedText would still reflect the old state.
                thread::sleep(Duration::from_millis(80));

                // Try AX first (no clipboard interference)
                let ax_result = read_selected_text_via_ax()
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty());

                if let Some(post_trimmed) = ax_result {
                    if let Some(pre_text) = pre {
                        if pre_text == post_trimmed {
                            log_native("selection unchanged, skipping toolbar");
                            return;
                        }
                    }
                    log_native(&format!("AX selection changed length={}", post_trimmed.len()));
                    show_toolbar(toolbar_port, post_trimmed, position, false);
                }
            });
        }
        CGEventType::KeyDown if is_translate_shortcut(event) => {
            log_native("shortcut key detected");
            let app = app.clone();
            thread::spawn(move || {
                trigger_popup_with_selection(&app);
            });
        }
        CGEventType::KeyDown if is_copy_command(event) => {
            // User pressed Cmd+C. Schedule a check: if the pasteboard actually
            // changes (i.e. there was a selection to copy), pop the toolbar.
            // This is the browser fallback — AX can't read Chrome/Safari/Edge
            // selections, so we rely on the user's explicit copy.
            let app = app.clone();
            thread::spawn(move || {
                handle_copy_for_toolbar(&app);
            });
        }
        CGEventType::FlagsChanged => {
            handle_flags_changed(app, event);
        }
        _ => {}
    }
}

fn accessibility_string_attribute(
    element: AXUIElementRef,
    attribute: &'static str,
) -> Option<String> {
    unsafe {
        let attribute = CFString::from_static_string(attribute);
        let mut value: CFTypeRef = ptr::null();
        let result =
            AXUIElementCopyAttributeValue(element, attribute.as_concrete_TypeRef(), &mut value);
        if result != AX_ERROR_SUCCESS || value.is_null() {
            return None;
        }

        let value = CFType::wrap_under_create_rule(value);
        value.downcast::<CFString>().map(|text| text.to_string())
    }
}

/// Check if the given screen position is on a text-selectable element.
/// Returns false for window chrome (title bar, toolbar, buttons, scroll bars, menus).
fn is_text_area_at_position(x: f64, y: f64) -> bool {
    unsafe {
        let system = AXUIElementCreateSystemWide();
        if system.is_null() {
            return true;
        }

        let mut element: AXUIElementRef = ptr::null();
        let result = AXUIElementCopyElementAtPosition(
            system,
            x as f32,
            y as f32,
            &mut element,
        );
        CFRelease(system as CFTypeRef);

        if result != AX_ERROR_SUCCESS || element.is_null() {
            return true;
        }

        let role = accessibility_string_attribute(element, "AXRole");
        CFRelease(element as CFTypeRef);

        match role.as_deref() {
            Some("AXWindow") | Some("AXToolbar") | Some("AXButton") |
            Some("AXPopUpButton") | Some("AXCheckBox") | Some("AXRadioButton") |
            Some("AXMenuBar") | Some("AXMenuBarItem") | Some("AXMenuItem") |
            Some("AXScrollBar") | Some("AXSlider") | Some("AXStepper") |
            Some("AXGrowArea") | Some("AXCloseButton") | Some("AXMinimizeButton") |
            Some("AXZoomButton") | Some("AXFullScreenButton") => {
                log_native(&format!(
                    "non-text click at ({x:.0},{y:.0}) role={}",
                    role.unwrap_or_default()
                ));
                false
            }
            _ => true,
        }
    }
}

fn is_translate_shortcut(event: &CGEvent) -> bool {
    let mode = current_popup_shortcut();
    let ShortcutMode::KeyCombo { cmd, shift, ctrl, alt, key_code } = mode else {
        return false; // DoubleCtrl is handled via FlagsChanged, not KeyDown
    };
    let event_key_code = event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYCODE) as u16;
    let flags = event.get_flags();
    event_key_code == key_code
        && (!cmd || flags.contains(CGEventFlags::CGEventFlagCommand))
        && (!shift || flags.contains(CGEventFlags::CGEventFlagShift))
        && (!ctrl || flags.contains(CGEventFlags::CGEventFlagControl))
        && (!alt || flags.contains(CGEventFlags::CGEventFlagAlternate))
}

/// Detect a plain Cmd+C (no other modifiers). Used to spot the user's own
/// copy action — we then watch for a resulting pasteboard changeCount bump
/// and pop the toolbar. This is the browser fallback path: native macOS apps
/// are handled via AX on mouse-up, but Chrome/Safari/Edge don't expose
/// AXSelectedText, so we only get the text when the user explicitly copies.
fn is_copy_command(event: &CGEvent) -> bool {
    let event_key_code = event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYCODE) as u16;
    if event_key_code != KeyCode::ANSI_C as u16 {
        return false;
    }
    let flags = event.get_flags();
    flags.contains(CGEventFlags::CGEventFlagCommand)
        && !flags.contains(CGEventFlags::CGEventFlagShift)
        && !flags.contains(CGEventFlags::CGEventFlagControl)
        && !flags.contains(CGEventFlags::CGEventFlagAlternate)
}

/// Maximum time between two Ctrl presses to count as a double-press (ms).
const DOUBLE_CTRL_INTERVAL_MS: u64 = 300;

/// Handle modifier key state changes for double-Ctrl detection.
fn handle_flags_changed(app: &tauri::AppHandle, event: &CGEvent) {
    if !matches!(current_popup_shortcut(), ShortcutMode::DoubleCtrl) {
        return;
    }

    let flags = event.get_flags();
    let ctrl_pressed = flags.contains(CGEventFlags::CGEventFlagControl);

    if !ctrl_pressed {
        return; // Only act on Ctrl press, not release
    }

    let now = Instant::now();
    let triggered = if let Ok(mut last) = LAST_CTRL_PRESS.lock() {
        match *last {
            Some(prev) if now.duration_since(prev).as_millis() as u64 <= DOUBLE_CTRL_INTERVAL_MS => {
                *last = None; // Reset to prevent triple-press
                true
            }
            _ => {
                *last = Some(now);
                false
            }
        }
    } else {
        false
    };

    if triggered {
        log_native("double-ctrl shortcut detected");
        let app = app.clone();
        thread::spawn(move || {
            trigger_popup_with_selection(&app);
        });
    }
}

/// Show popup and read selected text — shared by KeyDown and FlagsChanged shortcut handlers.
fn trigger_popup_with_selection(app: &tauri::AppHandle) {
    let _ = show_popup(app);
    thread::sleep(Duration::from_millis(35));

    // AX first — works for native macOS apps (Notes/TextEdit/Mail/Terminal/...).
    let (text, source) = match read_selected_text_via_ax() {
        Some(s) => {
            let trimmed = s.trim().to_string();
            if trimmed.is_empty() {
                (None, "ax-empty")
            } else {
                (Some(trimmed), "ax")
            }
        }
        None => (None, "none"),
    };

    // Browser fallback: AX can't read Chrome/Safari/Edge selections, so use
    // the text the user just Cmd+C'd, if it's still fresh.
    let (text, source) = match text {
        Some(t) => (Some(t), source),
        None => {
            let fallback = LAST_COPIED_TEXT
                .get_or_init(|| Mutex::new(None))
                .lock()
                .ok()
                .and_then(|cell| {
                    cell.as_ref().and_then(|(t, when)| {
                        if when.elapsed().as_secs() < COPIED_TEXT_FRESH_SECS {
                            Some(t.clone())
                        } else {
                            None
                        }
                    })
                });
            match fallback {
                Some(t) => (Some(t), "copied"),
                None => (None, source),
            }
        }
    };

    match text {
        Some(t) => {
            log_native(&format!("shortcut text length={} source={}", t.len(), source));
            let _ = app.emit(
                "lexi://ai-request",
                AiRequestPayload {
                    text: t,
                    mode: "popup_card",
                    feature_id: "translation".to_string(),
                },
            );
        }
        None => {
            log_native(&format!("shortcut no selected text (source={})", source));
        }
    }
}

/// Called when the user presses Cmd+C. Wait for the system to update the
/// pasteboard, then check changeCount. If it bumped, the user actually copied
/// something — pop the toolbar with that text. If it didn't bump, the user
/// pressed Cmd+C with no selection, do nothing.
/// User pressed Cmd+C. We don't pop any UI — just record what they copied,
/// with a timestamp. Later, when the user hits the Ctrl+Ctrl popup shortcut
/// and AX can't read the selection (browsers), we fall back to this record.
/// This is the only way to get selected text out of Chrome/Safari/Edge
/// without synthesizing keys (which prints stray characters).
fn handle_copy_for_toolbar(_app: &tauri::AppHandle) {
    // Cmd+C is async — the app processes the shortcut after our KeyDown tap
    // sees it. 150ms is enough on a quiet machine; bump if testing shows misses.
    thread::sleep(Duration::from_millis(150));

    log_native("copy-handler: about to read changeCount");

    let new_count = unsafe { pasteboard_change_count() };
    log_native(&format!("copy-handler: changeCount={new_count}"));

    let bumped = LAST_PASTEBOARD_CHANGE_COUNT
        .get_or_init(|| Mutex::new(0))
        .lock()
        .ok()
        .map(|mut cell| {
            let prev = *cell;
            if new_count > prev {
                *cell = new_count;
                true
            } else {
                false
            }
        })
        .unwrap_or(false);

    if !bumped {
        log_native("copy-handler: changeCount not bumped, skipping");
        return;
    }

    log_native("copy-handler: about to read pasteboard");
    let Some(text) = read_pasteboard_string_via_pb() else {
        log_native("copy-handler: pasteboard had no utf8 text");
        return;
    };

    let trimmed = text.trim().to_string();
    if trimmed.is_empty() {
        log_native("copy-handler: pasteboard text empty after trim");
        return;
    }

    log_native(&format!("copy-handler: recorded text len={}", trimmed.len()));
    if let Ok(mut cell) = LAST_COPIED_TEXT
        .get_or_init(|| Mutex::new(None))
        .lock()
    {
        *cell = Some((trimmed, Instant::now()));
    }
}

/// Read selected text via Accessibility API (no clipboard pollution).
fn read_selected_text_via_ax() -> Option<String> {
    unsafe {
        let system = AXUIElementCreateSystemWide();
        if system.is_null() {
            return None;
        }

        // Get the focused UI element
        let mut focused: AXUIElementRef = ptr::null();
        let attr = CFString::from_static_string("AXFocusedUIElement");
        let result = AXUIElementCopyAttributeValue(
            system,
            attr.as_concrete_TypeRef(),
            &mut focused,
        );
        CFRelease(system as CFTypeRef);

        if result != AX_ERROR_SUCCESS || focused.is_null() {
            return None;
        }

        // Try AXSelectedText directly
        if let Some(text) = accessibility_string_attribute(focused, "AXSelectedText") {
            CFRelease(focused as CFTypeRef);
            return Some(text);
        }

        // Fallback: extract selected text from AXValue + AXSelectedTextRange.
        // Some apps (e.g. terminal emulators) don't support AXSelectedText but do
        // expose the full text content via AXValue and the selection range via
        // AXSelectedTextRange. Combining these lets us read the selection without
        // simulating Cmd+C (which clears the selection in those apps).
        let text = read_selected_text_via_ax_range(focused);
        CFRelease(focused as CFTypeRef);
        text
    }
}

/// Try to extract selected text by reading AXValue and slicing with AXSelectedTextRange.
fn read_selected_text_via_ax_range(element: AXUIElementRef) -> Option<String> {
    unsafe {
        let full_text = accessibility_string_attribute(element, "AXValue")?;

        let range_attr = CFString::from_static_string("AXSelectedTextRange");
        let mut value: CFTypeRef = ptr::null();
        let result =
            AXUIElementCopyAttributeValue(element, range_attr.as_concrete_TypeRef(), &mut value);
        if result != AX_ERROR_SUCCESS || value.is_null() {
            return None;
        }

        // AXSelectedTextRange is stored as an AXValue containing a CFRange.
        // AXValueType for CFRange is 2 (kAXValueCFRangeType).
        let range = {
            let mut cf_range: core_foundation::base::CFRange = core_foundation::base::CFRange {
                location: 0,
                length: 0,
            };
            let ok = AXValueGetValue(
                value,
                2, // kAXValueCFRangeType
                &mut cf_range as *mut _ as *mut std::ffi::c_void,
            );
            CFRelease(value as CFTypeRef);
            if !ok {
                return None;
            }
            cf_range
        };

        let start = range.location as usize;
        let end = start + range.length as usize;
        if start >= full_text.len() || end > full_text.len() || range.length == 0 {
            return None;
        }

        Some(full_text[start..end].to_string())
    }
}

/// Returns the general NSPasteboard. Used to detect user-initiated Cmd+C
/// (via changeCount) and read the resulting text — never to write.
unsafe fn pasteboard_object() -> *mut std::ffi::c_void {
    let class = objc_getClass(b"NSPasteboard\0".as_ptr() as *const i8);
    if class.is_null() {
        return ptr::null_mut();
    }
    let sel = sel_registerName(b"generalPasteboard\0".as_ptr() as *const i8);
    objc_msgSend(class as *mut std::ffi::c_void, sel)
}

/// NSPasteboard changeCount — increments every time the pasteboard is written.
/// Used to detect that a real Cmd+C landed (vs. the user just pressing the
/// shortcut with no selection).
unsafe fn pasteboard_change_count() -> isize {
    let pb = pasteboard_object();
    if pb.is_null() {
        return 0;
    }
    let sel = sel_registerName(b"changeCount\0".as_ptr() as *const i8);
    objc_msgSend(pb, sel) as isize
}

/// Read the current UTF-8 plain-text contents of the pasteboard via `pbpaste`.
/// Avoids direct ObjC `stringForType:` on background threads — that path was
/// crashing the process (autoreleased NSString + reference-count subtleties).
/// pbpaste is ~30-80ms, fine for our 150ms-delayed read.
fn read_pasteboard_string_via_pb() -> Option<String> {
    let output = Command::new("pbpaste")
        .env("LANG", "en_US.UTF-8")
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&output.stdout).into_owned();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

fn write_clipboard(text: &str) -> Result<(), String> {
    write_clipboard_bytes(text.as_bytes())
}

fn write_clipboard_bytes(data: &[u8]) -> Result<(), String> {
    let mut child = Command::new("pbcopy")
        .env("LANG", "en_US.UTF-8")
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|error| format!("Failed to run pbcopy: {error}"))?;

    if let Some(stdin) = child.stdin.as_mut() {
        stdin
            .write_all(data)
            .map_err(|error| format!("Failed to write clipboard: {error}"))?;
    }

    let status = child
        .wait()
        .map_err(|error| format!("Failed to finish pbcopy: {error}"))?;

    if !status.success() {
        return Err(format!("pbcopy exited with status {status}"));
    }

    Ok(())
}

/// Cursor location at a mouse event, in Cocoa global coordinates (origin at the
/// bottom-left of the primary display, y up) — the space the toolbar helper's
/// `NSScreen`/`NSPanel` use. `event.location()` is in Core Graphics space
/// (top-left origin, y down), so flip y to match `mouse_location()` and keep
/// both toolbar show paths on the same coordinate system.
fn appkit_position_from_event(event: &CGEvent) -> CursorPosition {
    let loc = event.location();
    let primary_height = CGDisplay::main().bounds().size.height as f64;
    CursorPosition {
        x: loc.x.round() as i32,
        y: (primary_height - loc.y).round() as i32,
    }
}

fn show_toolbar(toolbar_port: u16, text: String, position: CursorPosition, pending: bool) {
    let Some(actions) = active_toolbar_actions() else {
        log_native("toolbar show ignored disabled or empty actions");
        return;
    };

    let payload = ToolbarShowPayload {
        text,
        x: position.x,
        y: position.y,
        pending,
        actions,
    };
    let Ok(body) = serde_json::to_string(&payload) else {
        return;
    };

    match post_to_helper(toolbar_port, "/show", &body) {
        Ok(()) => {
            log_native(&format!(
                "posted toolbar show x={} y={}",
                payload.x, payload.y
            ));
        }
        Err(error) => {
            log_native(&format!("toolbar show post failed: {error}"));
        }
    }
}

fn wait_for_helper(toolbar_port: u16) {
    for attempt in 0..20 {
        if TcpStream::connect((IPC_HOST, toolbar_port)).is_ok() {
            log_native(&format!("helper ready on port {toolbar_port} after {attempt} tries"));
            eprintln!("[toolbar] helper ready on port {toolbar_port}");
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(250));
    }
    log_native(&format!("helper NOT ready on port {toolbar_port} after 5s"));
    eprintln!("[toolbar] WARNING: helper did not respond on port {toolbar_port} after 5s");
}

fn post_to_helper(port: u16, path: &str, body: &str) -> std::io::Result<()> {
    let mut stream = TcpStream::connect((IPC_HOST, port))?;
    write!(
        stream,
        "POST {path} HTTP/1.1\r\nHost: {IPC_HOST}:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}

fn dispatch_toolbar_action(
    app: &tauri::AppHandle,
    action: ToolbarActionRequest,
) -> Result<(), String> {
    let text = action.text.trim().to_string();
    if text.is_empty() {
        return Err("empty text".into());
    }

    log_native(&format!("dispatch: action={}", action.action));

    let action_id = action.action.as_str();

    // Built-in tools: fixed backend execution
    match action_id {
        "copy" | "search" | "read" | "speak" | "note" | "handoff" => {
            let app_handle = app.clone();
            let id = action_id.to_string();
            tauri::async_runtime::spawn(async move {
                if let Err(e) = crate::commands::tools::execute_tool(app_handle, id, text).await {
                    eprintln!("[toolbar] tool failed: {e}");
                }
            });
            Ok(())
        }
        // Features (AI): open popup to run feature
        _ => open_popup_with_feature(app, text, action_id),
    }
}

fn open_popup_with_feature(
    app: &tauri::AppHandle,
    text: String,
    feature_id: &str,
) -> Result<(), String> {
    show_popup(app)?;
    app.emit(
        "lexi://ai-request",
        AiRequestPayload {
            text,
            mode: "popup_card",
            feature_id: feature_id.to_string(),
        },
    )
    .map_err(|error| format!("Could not emit AI request: {error}"))
}

fn show_popup(app: &tauri::AppHandle) -> Result<(), String> {
    let handle = app.clone();
    let task_handle = handle.clone();

    handle
        .run_on_main_thread(move || {
            if let Err(error) = show_popup_now(&task_handle) {
                log_native(&format!("Could not show popup: {error}"));
            }
        })
        .map_err(|error| format!("Could not schedule popup show: {error}"))?;

    Ok(())
}

fn show_popup_now(app: &tauri::AppHandle) -> Result<(), String> {
    let Some(window) = app.get_webview_window("popup_card") else {
        return Err("popup window was not found".into());
    };

    let already_visible = window.is_visible().unwrap_or(false);

    if already_visible {
        // Bring to front without stealing focus from the source app
        show_window_without_focus(&window);
        return Ok(());
    }

    let cursor = cursor_position();
    window
        .set_size(LogicalSize::new(DEFAULT_POPUP_SIZE, DEFAULT_POPUP_SIZE))
        .map_err(|error| format!("Could not reset popup size: {error}"))?;

    let pos = smart_popup_position(cursor.x, cursor.y, DEFAULT_POPUP_SIZE as i32);
    window
        .set_position(LogicalPosition::new(pos.0, pos.1))
        .map_err(|error| format!("Could not position popup: {error}"))?;

    // Emit before show so content clears while window is still hidden
    app.emit(
        "lexi://popup-shown",
        PopupShownPayload { mode: "popup_card" },
    )
    .map_err(|error| format!("Could not emit popup shown: {error}"))?;

    // Show without stealing focus — preserves text selection in the source app
    show_window_without_focus(&window);

    Ok(())
}

/// Compute smart popup position: default is below-right of cursor,
/// but if not enough space below on the current screen, place above instead.
fn smart_popup_position(cursor_x: i32, cursor_y: i32, popup_height: i32) -> (f64, f64) {
    let offset_x = 16;
    let offset_y = 18;
    let x = (cursor_x + offset_x) as f64;

    // Find which screen the cursor is on and get its bottom edge
    let screen_bottom = screen_bottom_at(cursor_x, cursor_y);

    let below_y = (cursor_y + offset_y) as f64;
    if below_y + popup_height as f64 <= screen_bottom {
        // Enough space below: place below-right
        (x, below_y)
    } else {
        // Not enough space below: place above-right
        (x, (cursor_y - popup_height - offset_y) as f64)
    }
}

/// Find the bottom edge (in tao top-left-origin coords) of the screen containing the cursor.
fn screen_bottom_at(cursor_x: i32, cursor_y: i32) -> f64 {
    let Ok(displays) = CGDisplay::active_displays() else {
        return f64::MAX;
    };

    for display_id in displays {
        let display = CGDisplay::new(display_id);
        let bounds = display.bounds();
        let x_min = bounds.origin.x as i32;
        let y_min = bounds.origin.y as i32;
        let x_max = x_min + bounds.size.width as i32;
        let y_max = y_min + bounds.size.height as i32;

        if cursor_x >= x_min && cursor_x < x_max && cursor_y >= y_min && cursor_y < y_max {
            return y_max as f64;
        }
    }

    // Fallback: use main display
    CGDisplay::main().bounds().origin.y as f64
        + CGDisplay::main().bounds().size.height as f64
}

#[tauri::command]
pub fn popup_position(popup_height: i32) -> CursorPosition {
    let cursor = cursor_position();
    let pos = smart_popup_position(cursor.x, cursor.y, popup_height);
    CursorPosition {
        x: pos.0.round() as i32,
        y: pos.1.round() as i32,
    }
}

#[tauri::command]
pub fn set_handoff_target(target_app: String) -> Result<(), String> {
    log_native(&format!("set_handoff_target: '{}'", target_app));
    let mut current = HANDOFF_TARGET_APP
        .get_or_init(|| Mutex::new("ChatGPT".to_string()))
        .lock()
        .map_err(|_| "handoff target app state is unavailable".to_string())?;
    *current = target_app;
    Ok(())
}

#[tauri::command]
pub fn handoff_to_app_cmd(text: String, target_app: String) -> Result<(), String> {
    do_handoff(&text, &target_app)
}

fn do_handoff(text: &str, target_app: &str) -> Result<(), String> {
    let app = if target_app.is_empty() { "ChatGPT" } else { target_app };
    log_native(&format!("handoff: target={}, text_len={}", app, text.len()));

    // Write text to clipboard
    write_clipboard(text)?;

    // AppleScript: activate target app, then paste
    let script = format!(
        r#"set the clipboard to "{}"
tell application "{}" to activate
delay 1.0
tell application "System Events"
    keystroke "v" using command down
end tell"#,
        text.replace('\\', "\\\\").replace('"', "\\\""),
        app.replace('\\', "\\\\").replace('"', "\\\""),
    );

    log_native(&format!("handoff: script len={}", script.len()));

    let output = Command::new("osascript")
        .arg("-e")
        .arg(&script)
        .output()
        .map_err(|error| format!("Could not run handoff: {error}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        log_native(&format!("handoff: osascript failed: {}", stderr));
        return Err(format!("osascript error: {}", stderr));
    }

    log_native("handoff: completed successfully");
    Ok(())
}

fn read_http_request(stream: &mut TcpStream) -> std::io::Result<Vec<u8>> {
    stream.set_read_timeout(Some(Duration::from_millis(300)))?;

    let mut buffer = Vec::new();
    let mut chunk = [0_u8; 2048];

    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(read) => {
                buffer.extend_from_slice(&chunk[..read]);
                if request_body_complete(&buffer) {
                    break;
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted
                ) =>
            {
                if !buffer.is_empty() {
                    break;
                }
            }
            Err(error) => return Err(error),
        }
    }

    Ok(buffer)
}

fn request_body_complete(buffer: &[u8]) -> bool {
    let request = String::from_utf8_lossy(buffer);
    let Some(header_end) = request.find("\r\n\r\n") else {
        return false;
    };

    let content_length = request
        .lines()
        .find_map(|line| line.strip_prefix("Content-Length:"))
        .and_then(|value| value.trim().parse::<usize>().ok())
        .unwrap_or(0);
    let body_start = header_end + 4;

    buffer.len().saturating_sub(body_start) >= content_length
}

fn write_response(stream: &mut TcpStream, status: u16, body: &str) -> std::io::Result<()> {
    let status_text = if status == 200 { "OK" } else { "ERROR" };
    write!(
        stream,
        "HTTP/1.1 {status} {status_text}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}


fn launch_helper(app: &tauri::App, action_port: u16, toolbar_port: u16) -> anyhow::Result<()> {
    let helper_app = helper_app_path(app)?;
    if !helper_app.exists() {
        eprintln!(
            "Native selection toolbar helper app was not found: {}",
            helper_app.display()
        );
        log_native(&format!("helper not found at {}", helper_app.display()));
        return Ok(());
    }

    log_native(&format!("launching helper at {}", helper_app.display()));

    let helper_bin = helper_app.join("Contents/MacOS/LexiSelectionHelper");
    Command::new(&helper_bin)
        .arg("--action-port")
        .arg(action_port.to_string())
        .arg("--toolbar-port")
        .arg(toolbar_port.to_string())
        .spawn()?;

    eprintln!("[toolbar] helper launch attempted: action={action_port}, toolbar={toolbar_port}");
    log_native(&format!("helper launch attempted, action={action_port}, toolbar={toolbar_port}"));
    Ok(())
}

fn helper_app_path(app: &tauri::App) -> anyhow::Result<PathBuf> {
    if let Ok(resource_dir) = app.path().resource_dir() {
        let bundled = resource_dir.join("native/LexiSelectionHelper.app");
        if bundled.exists() {
            return Ok(bundled);
        }
    }

    Ok(env::current_dir()?.join("native/LexiSelectionHelper.app"))
}

fn request_system_permissions() {
    let listen_granted = unsafe { CGPreflightListenEventAccess() };
    let post_granted = unsafe { CGPreflightPostEventAccess() };
    log_native(&format!(
        "permission status listen={} post={}",
        listen_granted, post_granted
    ));

    if !listen_granted {
        unsafe {
            CGRequestListenEventAccess();
        }
    }
    if !post_granted {
        unsafe {
            CGRequestPostEventAccess();
        }
    }
    if !listen_granted {
        open_privacy_settings("Privacy_ListenEvent");
    }
    if !post_granted {
        open_privacy_settings("Privacy_Accessibility");
    }
}

fn log_native(message: &str) {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or_default();
    let line = format!("{timestamp} {message}\n");

    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(LOG_PATH) {
        let _ = file.write_all(line.as_bytes());
    }
}

fn open_privacy_settings(pane: &str) {
    let _ = Command::new("open")
        .arg(format!(
            "x-apple.systempreferences:com.apple.preference.security?{pane}"
        ))
        .spawn();
}

#[link(name = "CoreGraphics", kind = "framework")]
#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn CGPreflightListenEventAccess() -> bool;
    fn CGRequestListenEventAccess() -> bool;
    fn CGPreflightPostEventAccess() -> bool;
    fn CGRequestPostEventAccess() -> bool;
    fn AXUIElementCreateSystemWide() -> AXUIElementRef;
    fn AXUIElementCopyAttributeValue(
        element: AXUIElementRef,
        attribute: CFStringRef,
        value: *mut CFTypeRef,
    ) -> i32;
    fn AXUIElementCopyElementAtPosition(
        application: AXUIElementRef,
        x: f32,
        y: f32,
        element: *mut AXUIElementRef,
    ) -> i32;
    fn AXValueGetValue(
        value: CFTypeRef,
        the_type: u32,
        range_ptr: *mut std::ffi::c_void,
    ) -> bool;
}
