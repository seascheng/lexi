use crate::cursor::{cursor_position, mouse_location, CursorPosition};
use crate::ax::{
    accessibility_bool_attribute, accessibility_string_attribute, ax_children,
    ax_focused_application, copy_ax_element_attribute, copy_marker_range,
    drain_autorelease_pool, frontmost_pid, new_autorelease_pool, objc_getClass, objc_msgSend,
    sel_registerName, AXUIElementSetMessagingTimeout, AX_ERROR_SUCCESS,
    AXUIElementCopyAttributeValue, AXUIElementCopyElementAtPosition,
    AXUIElementCopyParameterizedAttributeValue, AXUIElementCreateSystemWide, AXUIElementGetPid,
    AXUIElementPerformAction, AXValueGetValue, AXUIElementRef, CFArrayGetCount,
    CFArrayGetValueAtIndex,
};
use crate::text_injection;
use core_foundation::base::{CFRelease, CFType, CFTypeRef, TCFType};
use core_foundation::runloop::CFRunLoop;
use core_foundation::string::{CFString, CFStringRef};
use core_graphics::event::{
    CGEvent, CGEventFlags, CGEventTap, CGEventTapLocation, CGEventTapOptions, CGEventTapPlacement,
    CGEventType, CallbackResult, EventField, KeyCode,
};
use core_graphics::display::CGDisplay;
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use serde::{Deserialize, Serialize};

// Window-bounds FFI for the drag detector: CGWindowList (the window server)
// answers for every app, including self-drawn editors whose degenerate AX
// trees expose no AXFocusedWindow at all (Sublime).
#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGWindowListCopyWindowInfo(options: u32, relative_to: u32) -> *const std::ffi::c_void;
    fn CGRectMakeWithDictionaryRepresentation(
        dict: *const std::ffi::c_void,
        rect: *mut core_graphics::geometry::CGRect,
    ) -> bool;
}
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFDictionaryGetValue(
        dict: *const std::ffi::c_void,
        key: CFStringRef,
    ) -> *const std::ffi::c_void;
    fn CFNumberGetValue(
        number: *const std::ffi::c_void,
        the_type: isize,
        value_ptr: *mut std::ffi::c_void,
    ) -> bool;
}

/// Origin (CG global top-left coords — the same space CGEvent locations
/// use) of the frontmost normal window owned by `pid`, via CGWindowList.
/// Layer-0 filter skips menus, desktop and overlay windows.
unsafe fn cg_window_origin(pid: i32) -> Option<(f64, f64)> {
    const ON_SCREEN_ONLY: u32 = 1 << 0;
    let list = CGWindowListCopyWindowInfo(ON_SCREEN_ONLY, 0);
    if list.is_null() {
        return None;
    }
    let count = CFArrayGetCount(list);
    let mut result = None;
    for i in 0..count {
        let dict = CFArrayGetValueAtIndex(list, i);
        if dict.is_null() {
            continue;
        }
        let pid_key = CFString::from_static_string("kCGWindowOwnerPID");
        let value = CFDictionaryGetValue(dict, pid_key.as_concrete_TypeRef());
        let mut owner: i32 = 0;
        if value.is_null()
            || !CFNumberGetValue(value, 3, &mut owner as *mut i32 as *mut std::ffi::c_void)
            || owner != pid
        {
            continue;
        }
        let layer_key = CFString::from_static_string("kCGWindowLayer");
        let layer_value = CFDictionaryGetValue(dict, layer_key.as_concrete_TypeRef());
        let mut layer: i32 = -1;
        if !layer_value.is_null()
            && CFNumberGetValue(layer_value, 3, &mut layer as *mut i32 as *mut std::ffi::c_void)
            && layer != 0
        {
            continue;
        }
        let bounds_key = CFString::from_static_string("kCGWindowBounds");
        let bounds = CFDictionaryGetValue(dict, bounds_key.as_concrete_TypeRef());
        if bounds.is_null() {
            continue;
        }
        let mut rect = core_graphics::geometry::CGRect {
            origin: core_graphics::geometry::CGPoint { x: 0.0, y: 0.0 },
            size: core_graphics::geometry::CGSize { width: 0.0, height: 0.0 },
        };
        if CGRectMakeWithDictionaryRepresentation(bounds, &mut rect) {
            result = Some((rect.origin.x, rect.origin.y));
            break;
        }
    }
    CFRelease(list);
    result
}
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
use tauri::{Emitter, Manager};



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

const IPC_HOST: &str = "127.0.0.1";
const LOG_PATH: &str = "/tmp/lexi-native-toolbar.log";
/// Fixed port the Chrome extension POSTs selected text to. Hardcoded so the
/// extension doesn't have to discover a dynamic port. Collisions are unlikely
/// (nothing else commonly uses 47xxx range).
const EXTENSION_PORT: u16 = 47291;


static TOOLBAR_PORT: OnceLock<Mutex<Option<u16>>> = OnceLock::new();
static TOOLBAR_ACTIONS: OnceLock<Mutex<Vec<ToolbarActionItem>>> = OnceLock::new();
static TOOLBAR_ENABLED: OnceLock<Mutex<bool>> = OnceLock::new();
static POPUP_SHORTCUT: OnceLock<Mutex<ShortcutMode>> = OnceLock::new();
static LAST_CTRL_PRESS: Mutex<Option<Instant>> = Mutex::new(None);
static HANDOFF_TARGET_APP: OnceLock<Mutex<String>> = OnceLock::new();
static EXCLUDED_TOOLBAR_APPS: OnceLock<Mutex<Vec<String>>> = OnceLock::new();

/// The app the user's last selection/popup gesture came from — the write-back
/// target for text injection. Captured while the source app is still frontmost
/// (the popup shows without activating lexi, so this usually stays valid).
#[derive(Clone)]
pub(crate) struct SelectionTarget {
    pub(crate) pid: i32,
    pub(crate) bundle_id: String,
    pub(crate) captured_at: Instant,
}

/// How long after capture a selection target still accepts write-back.
const SELECTION_TARGET_FRESH_SECS: u64 = 60;

static SELECTION_TARGET: std::sync::LazyLock<Mutex<Option<SelectionTarget>>> =
    std::sync::LazyLock::new(|| Mutex::new(None));

/// Remember the frontmost app as the write-back target (skips lexi itself).
pub(crate) fn capture_selection_target() {
    unsafe {
        let Some(pid) = frontmost_pid() else { return };
        if pid == std::process::id() as i32 {
            return;
        }
        let bundle_id = frontmost_bundle_id().unwrap_or_default();
        log_native(&format!("selection target captured pid={pid} bundle={bundle_id}"));
        if let Ok(mut cell) = SELECTION_TARGET.lock() {
            *cell = Some(SelectionTarget {
                pid,
                bundle_id,
                captured_at: Instant::now(),
            });
        }
    }
}

/// The captured target, if still fresh.
pub(crate) fn current_selection_target() -> Option<SelectionTarget> {
    let target = SELECTION_TARGET.lock().ok()?.clone()?;
    (target.captured_at.elapsed().as_secs() <= SELECTION_TARGET_FRESH_SECS).then_some(target)
}


/// Popup-on-screen flag, read by the event tap. MUST stay an O(1) atomic —
/// querying the window from the tap hops to the main thread, and a busy main
/// thread stalls the tap until macOS kills it (kCGEventTapDisabledByTimeout),
/// which turned arrow keys into "every other one works". The frontend reports
/// hides via the `set_popup_up` command; Rust sets it on show/Esc/outside-click.
/// Global handle for deferred native-card work (sqlite access from workers).
static CURRENT_APP: OnceLock<tauri::AppHandle> = OnceLock::new();
static CARD_UP: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// Pid of the selection helper — selection reads inside our own UI (the
/// rename editor's select-all) must never trigger the toolbar.
static HELPER_PID: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);
static CARD_AUTO_SAVE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Last theme the frontend pushed. The helper defaults to dark and its
/// lifecycle is independent of the frontend (watchdog relaunches), so every
/// helper (re)start must be followed by a theme push — the cached value is
/// what those re-pushes use.
static LAST_THEME: std::sync::LazyLock<Mutex<String>> =
    std::sync::LazyLock::new(|| Mutex::new("dark".to_string()));

fn push_theme_to_helper(toolbar_port: u16) {
    let theme = LAST_THEME
        .lock()
        .map(|t| t.clone())
        .unwrap_or_else(|_| "dark".to_string());
    let Ok(body) = serde_json::to_string(&ToolbarThemePayload { theme }) else {
        return;
    };
    for attempt in 0..5 {
        match post_to_helper(toolbar_port, "/theme", &body) {
            Ok(()) => return,
            Err(e) if attempt < 4 => {
                log_native(&format!("theme push attempt {} failed: {e}", attempt + 1));
                std::thread::sleep(std::time::Duration::from_millis(500));
            }
            Err(e) => {
                log_native(&format!("theme push gave up: {e}"));
                return;
            }
        }
    }
}


pub(crate) fn card_auto_save_enabled() -> bool {
    CARD_AUTO_SAVE.load(std::sync::atomic::Ordering::Relaxed)
}

pub(crate) fn is_single_word(text: &str) -> bool {
    let word = text.trim().trim_matches(|c: char| !c.is_ascii_alphabetic());
    !word.is_empty()
        && word.chars().all(|c| c.is_ascii_alphabetic() || c == '-' || c == '\'')
}

/// Persist a learned entry (parity with the WebView flow's Save button).
pub(crate) fn save_word_entry(
    word: &str,
    translation: &str,
    pos: &str,
    definition: &str,
    example: &str,
    entry_type: &str,
) {
    if let Some(db) = current_app()
        .and_then(|app| app.path().app_data_dir().ok())
        .map(|dir| dir.join("lexi.db"))
    {
        let _ = Command::new("sqlite3")
            .arg(&db)
            .arg(format!(
                "INSERT INTO words (word, translation, pos, definition, example, status, entry_type, source_text) VALUES ('{}', '{}', '{}', '{}', '{}', 'new', '{}', '{}');",
                word.replace('\'', "''"),
                translation.replace('\'', "''"),
                pos.replace('\'', "''"),
                definition.replace('\'', "''"),
                example.replace('\'', "''"),
                entry_type.replace('\'', "''"),
                word.replace('\'', "''"),
            ));
    }
}

fn toolbar_port() -> Option<u16> {
    TOOLBAR_PORT
        .get_or_init(|| Mutex::new(None))
        .lock()
        .ok()
        .and_then(|cell| *cell)
}

fn current_app() -> Option<&'static tauri::AppHandle> {
    CURRENT_APP.get()
}

/// Read query results as a JSON string via `sqlite3 -json`.
fn sqlite_query_json(app: &tauri::AppHandle, query: &str) -> Option<String> {
    let db = app.path().app_data_dir().ok()?.join("lexi.db");
    if !db.exists() {
        return None;
    }
    let output = Command::new("sqlite3")
        .arg("-json")
        .arg(&db)
        .arg(query)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if stdout.is_empty() {
        None
    } else {
        Some(stdout)
    }
}

/// Open the native result card and stream `feature_id`'s AI run into it.
fn show_result_card(app: &tauri::AppHandle, text: &str, feature_id: &str) {
    let escaped_id = feature_id.replace('\'', "''");
    let Some(rows) = sqlite_query_json(
        app,
        &format!(
            "SELECT name, prompt_template, output_mode, IFNULL(target_language,'') AS target_language, IFNULL(icon,'wand') AS icon, auto_save_to_vocabulary, IFNULL(thinking,0) AS thinking FROM ai_features WHERE id = '{escaped_id}';"
        ),
    ) else {
        log_native("card: feature not found");
        return;
    };
    let Some(feature) = serde_json::from_str::<serde_json::Value>(&rows)
        .ok()
        .and_then(|v| v.as_array().and_then(|a| a.first()).cloned())
    else {
        log_native("card: feature parse failed");
        return;
    };

    let Some(settings) = sqlite_query_json(
        app,
        "SELECT key, value FROM settings WHERE key IN ('apiBaseUrl','apiKey','model');",
    ) else {
        log_native("card: settings unavailable");
        return;
    };
    let mut api_base_url = String::new();
    let mut api_key = String::new();
    let mut model = String::new();
    if let Ok(entries) = serde_json::from_str::<serde_json::Value>(&settings) {
        if let Some(list) = entries.as_array() {
            for entry in list {
                match entry["key"].as_str().unwrap_or("") {
                    "apiBaseUrl" => api_base_url = entry["value"].as_str().unwrap_or("").to_string(),
                    "apiKey" => api_key = entry["value"].as_str().unwrap_or("").to_string(),
                    "model" => model = entry["value"].as_str().unwrap_or("").to_string(),
                    _ => {}
                }
            }
        }
    }
    if api_base_url.is_empty() || model.is_empty() {
        log_native("card: API settings missing");
        return;
    }

    let title = feature["name"].as_str().unwrap_or("AI").to_string();
    let icon = feature["icon"].as_str().unwrap_or("wand").to_string();
    let auto_save = feature["auto_save_to_vocabulary"].as_i64().unwrap_or(0) == 1;
    CARD_AUTO_SAVE.store(auto_save, std::sync::atomic::Ordering::Relaxed);

    let run_id = format!(
        "card-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0)
    );
    if !post_card_show(&run_id, feature_id, &title, &icon, auto_save, text) {
        return;
    }

    let request = crate::commands::ai::AiRunRequest {
        text: text.to_string(),
        api_base_url,
        api_key,
        model,
        prompt_template: feature["prompt_template"].as_str().unwrap_or("").to_string(),
        output_mode: feature["output_mode"].as_str().unwrap_or("plain_text").to_string(),
        target_language: Some(feature["target_language"].as_str().unwrap_or("").to_string())
            .filter(|t| !t.is_empty()),
        thinking_enabled: feature["thinking"].as_i64().unwrap_or(0) == 1,
    };
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        if let Err(error) = crate::commands::ai::run_ai_prompt_stream(app.clone(), request, run_id).await {
            log_native(&format!("card: stream spawn failed: {error}"));
        }
    });
}

/// Show the card with no runs — the manual input surface (WebView parity:
/// the popup opens on AiForm + IdleState, runs append as they start).
fn show_idle_card(app: &tauri::AppHandle) {
    if !post_card_show("", "", "", "", false, "") {
        return;
    }
    log_native("card: idle input card shown");
    let _ = app;
}

/// POST /result-show (+ /card-actions) and raise CARD_UP. Returns false when
/// the helper is unreachable.
fn post_card_show(run_id: &str, feature_id: &str, title: &str, icon: &str, auto_save: bool, input_text: &str) -> bool {
    let Some(port) = toolbar_port() else { return false };
    let payload = serde_json::json!({
        "runId": run_id,
        "featureId": feature_id,
        "title": title,
        "icon": icon,
        "autoSave": auto_save,
        "inputText": input_text,
    });
    let Ok(body) = serde_json::to_string(&payload) else { return false };
    if post_to_helper(port, "/result-show", &body).is_err() {
        log_native("card: helper not reachable");
        return false;
    }
    // The input bar's action buttons mirror the WebView AiForm's panelItems:
    // toolbar tools with panelEnabled (settings.toolbar_tools) + enabled AI
    // features, merged by panel sort order — NOT the toolbar's action list.
    let (actions, panels) = panel_config_items();
    if let Ok(actions_body) = serde_json::to_string(&serde_json::json!({
        "actions": actions,
        "panels": panels,
    })) {
        let _ = post_to_helper(port, "/card-actions", &actions_body);
    }
    CARD_UP.store(true, std::sync::atomic::Ordering::Relaxed);
    true
}

/// WebView AiForm panelItems + panel tabs, straight from the Panel Config
/// surface: tools' panelEnabled (settings.toolbar_tools) and enabled AI
/// features, ordered by their panel sort order.
fn panel_config_items() -> (Vec<serde_json::Value>, Vec<serde_json::Value>) {
    let Some(app) = current_app() else { return (vec![], vec![]) };

    struct Item {
        order: i64,
        id: String,
        name: String,
        icon: String,
        kind: &'static str,
    }
    let mut items: Vec<Item> = vec![];

    // Tools: settings.toolbar_tools JSON (falls back to the built-in set the
    // frontend seeds on first run).
    let tools_json = sqlite_query_json(
        app,
        "SELECT value FROM settings WHERE key = 'toolbar_tools' LIMIT 1;",
    )
    // sqlite -json wraps rows: [{"value":"[{...tool...},...]"}] — the setting
    // itself is a JSON array, so unwrap twice or every tool gets skipped.
    .and_then(|json| serde_json::from_str::<serde_json::Value>(&json).ok())
    .and_then(|rows| rows.as_array().and_then(|a| a.first()).cloned())
    .and_then(|row| row["value"].as_str().map(str::to_string))
    .and_then(|inner| serde_json::from_str::<serde_json::Value>(&inner).ok())
    .and_then(|v| v.as_array().cloned());
    let tools_list = tools_json.unwrap_or_else(default_toolbar_tools_json);
    for tool in tools_list {
        if tool["panelEnabled"].as_bool() != Some(true) {
            continue;
        }
        let id = tool["id"].as_str().unwrap_or("").to_string();
        if id.is_empty() {
            continue;
        }
        items.push(Item {
            order: tool["panelSortOrder"].as_i64().unwrap_or_else(|| tool["sortOrder"].as_i64().unwrap_or(100)),
            id,
            name: tool["name"].as_str().unwrap_or("Tool").to_string(),
            icon: tool["icon"].as_str().unwrap_or("wand").to_string(),
            kind: "tool",
        });
    }

    // Features: ai_features has no panel_enabled column yet (the WebView
    // default is panel-visible), so enabled features all count.
    if let Some(rows) = sqlite_query_json(
        app,
        "SELECT id, name, IFNULL(icon, 'wand') AS icon, sort_order FROM ai_features WHERE enabled = 1;",
    )
        .and_then(|json| serde_json::from_str::<serde_json::Value>(&json).ok())
        .and_then(|v| v.as_array().cloned())
    {
        for feature in rows {
            let id = feature["id"].as_str().unwrap_or("").to_string();
            if id.is_empty() {
                continue;
            }
            items.push(Item {
                order: feature["sort_order"].as_i64().unwrap_or(0),
                id,
                name: feature["name"].as_str().unwrap_or("AI").to_string(),
                icon: feature["icon"].as_str().unwrap_or("wand").to_string(),
                kind: "feature",
            });
        }
    }

    items.sort_by_key(|item| item.order);
    let actions = items
        .into_iter()
        .map(|item| serde_json::json!({ "id": item.id, "name": item.name, "icon": item.icon, "kind": item.kind }))
        .collect();

    // Panel tabs: panels table merged with the three built-ins (frontend
    // withBuiltInPanels parity — missing ids are appended, not all-or-nothing).
    let mut panels: Vec<serde_json::Value> = sqlite_query_json(
        app,
        "SELECT id, name, icon FROM panels WHERE enabled = 1 ORDER BY sort_order;",
    )
        .and_then(|json| serde_json::from_str::<serde_json::Value>(&json).ok())
        .and_then(|v| v.as_array().cloned())
        .map(|rows| rows.to_vec())
        .unwrap_or_default();
    let builtin_order = ["translate", "notes", "review"];
    for (id, name, icon) in [
        ("translate", "Actions", "file-text"),
        ("notes", "Notes", "notebook-pen"),
        ("review", "Review", "book-open"),
    ] {
        if !panels.iter().any(|p| p["id"].as_str() == Some(id)) {
            panels.push(serde_json::json!({ "id": id, "name": name, "icon": icon }));
        }
    }
    // Canonical tab order: built-ins first (actions, notes, review), custom
    // panels keep their DB order after them.
    let mut ordered: Vec<serde_json::Value> = Vec::with_capacity(panels.len());
    for id in builtin_order {
        if let Some(pos) = panels.iter().position(|p| p["id"].as_str() == Some(id)) {
            ordered.push(panels.swap_remove(pos));
        }
    }
    ordered.append(&mut panels);

    (actions, ordered)
}

fn default_toolbar_tools_json() -> Vec<serde_json::Value> {
    vec![
        serde_json::json!({ "id": "copy", "name": "Copy", "icon": "copy", "panelEnabled": true, "panelSortOrder": 100 }),
        serde_json::json!({ "id": "search", "name": "Search", "icon": "search", "panelEnabled": true, "panelSortOrder": 110 }),
        serde_json::json!({ "id": "read", "name": "Read", "icon": "volume", "panelEnabled": true, "panelSortOrder": 120 }),
        serde_json::json!({ "id": "note", "name": "Note", "icon": "notebook-pen", "panelEnabled": true, "panelSortOrder": 130 }),
    ]
}
// ---------------------------------------------------------------------------
// Native Notes panel (Phase D, option B) — the helper renders the list with
// AppKit (zero webview throttling); Rust owns the snapshot and the selected
// index, and the event tap routes ↑↓/Enter/Esc. This is the Hapigo-style
// surface: the source app keeps its caret the whole time.
// ---------------------------------------------------------------------------

#[derive(Clone, Serialize, serde::Deserialize)]
struct NoteRow {
    #[serde(default)]
    id: Option<i64>,
    name: String,
    content: String,
    #[serde(default)]
    tags: Vec<String>,
}


static NOTES_SNAPSHOT: std::sync::LazyLock<Mutex<Vec<NoteRow>>> =
    std::sync::LazyLock::new(|| Mutex::new(Vec::new()));
static NOTES_SELECTED_NOTE_ID: std::sync::atomic::AtomicI64 = std::sync::atomic::AtomicI64::new(-1);




/// Insert the highlighted note at the source app's caret, then hide the panel.
fn notes_enter() {
    let wanted_id = NOTES_SELECTED_NOTE_ID.load(std::sync::atomic::Ordering::Relaxed);
    let text = NOTES_SNAPSHOT.lock().ok().and_then(|cell| {
        cell.iter()
            .find(|note| note.id == Some(wanted_id))
            .cloned()
    });
    let Some(note) = text.filter(|n| !n.content.trim().is_empty()) else {
        log_native("notes Enter: nothing selected");
        return;
    };
    match text_injection::deliver_text(&note.content) {
        Ok(tier) => {
            log_native(&format!("notes Enter: inserted via {tier}"));
            // Mirror the note onto the clipboard: the paste tier overwrote it
            // with the same content, but the AX tier did not touch it.
            write_pasteboard_string_via_pb(&note.content);
            notes_hide();
        }
        Err(error) => {
            // No text target (or delivery refused): degrade gracefully — copy
            // the note to the clipboard, dismiss, and let the user paste.
            log_native(&format!("notes Enter: insert failed ({}), copied instead", error));
            write_pasteboard_string_via_pb(&note.content);
            notes_hide();
        }
    }
}

/// Dismiss the native panel and clear its flag.
fn notes_hide() {
    let port = TOOLBAR_PORT
        .get_or_init(|| Mutex::new(None))
        .lock()
        .ok()
        .and_then(|cell| *cell);
    let Some(port) = port else { return };
    let _ = post_to_helper(port, "/notes-hide", "{}");
    let _ = post_to_helper(port, "/card-hide", "{}");
}

/// The helper hid the panel itself (outside click) — clear our flag.
pub(crate) fn mark_notes_hidden() {
}
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
struct ToolbarShowPayload {
    text: String,
    x: i32,
    y: i32,
    /// Mouse-down position (AppKit coords) for direction-aware placement.
    /// `None` on non-drag paths — the helper falls back to above-the-cursor.
    #[serde(rename = "downX")]
    down_x: Option<i32>,
    #[serde(rename = "downY")]
    down_y: Option<i32>,
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
    // Deferred native-card work (panel config reads, auto-save) needs an
    // AppHandle without threading one through every helper call site.
    let _ = CURRENT_APP.set(app.handle().clone());
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
    launch_helper(&app_handle, action_port, toolbar_port)?;
    wait_for_helper(toolbar_port);
    push_theme_to_helper(toolbar_port);
    spawn_helper_watchdog(app_handle.clone(), action_port, toolbar_port);
    spawn_selection_monitor(app_handle.clone(), toolbar_port);
    spawn_extension_server(&app_handle);
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
    if let Ok(mut cached) = LAST_THEME.lock() {
        *cached = theme.to_string();
    }
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

/// Bundle identifier of the frontmost application via NSWorkspace — native,
/// no subprocess. The previous osascript version cost 100-300ms per selection
/// gesture (spawned on every mouse-up).
unsafe fn frontmost_bundle_id() -> Option<String> {
    let pool = new_autorelease_pool();
    let id = frontmost_bundle_id_inner();
    drain_autorelease_pool(pool);
    id
}

unsafe fn frontmost_bundle_id_inner() -> Option<String> {
    let cls = objc_getClass(b"NSWorkspace\0".as_ptr() as *const i8);
    if cls.is_null() {
        return None;
    }
    let workspace = objc_msgSend(cls as *mut std::ffi::c_void, sel_registerName(b"sharedWorkspace\0".as_ptr() as *const i8));
    if workspace.is_null() {
        return None;
    }
    let running_app = objc_msgSend(workspace, sel_registerName(b"frontmostApplication\0".as_ptr() as *const i8));
    if running_app.is_null() {
        return None;
    }
    let ns_string = objc_msgSend(running_app, sel_registerName(b"bundleIdentifier\0".as_ptr() as *const i8));
    if ns_string.is_null() {
        return None;
    }
    let utf8 = objc_msgSend(ns_string, sel_registerName(b"UTF8String\0".as_ptr() as *const i8))
        as *const std::ffi::c_char;
    if utf8.is_null() {
        return None;
    }
    Some(std::ffi::CStr::from_ptr(utf8).to_string_lossy().into_owned())
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

fn toolbar_enabled_for_app(_app: &tauri::AppHandle) -> bool {
    // TOOLBAR_ENABLED / TOOLBAR_ACTIONS / EXCLUDED_TOOLBAR_APPS are pushed by
    // the frontend via configure_native_toolbar / set_excluded_toolbar_apps on
    // startup and on every settings change — no need to re-read SQLite or
    // spawn osascript here on every selection gesture.
    if !native_toolbar_enabled() {
        return false;
    }

    // Check if the frontmost app is in the exclusion list
    if let Some(bundle_id) = unsafe { frontmost_bundle_id() } {
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
fn spawn_extension_server(app_handle: &tauri::AppHandle) {
    let app_handle = app_handle.clone();
    thread::spawn(move || {
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
            let app = app_handle.clone();
            thread::spawn(move || handle_extension_connection(app, stream));
        }
    });
}

#[derive(Deserialize)]
struct ExtensionSelectionPayload {
    text: String,
}

fn handle_extension_connection(app: tauri::AppHandle, mut stream: TcpStream) {
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
        show_toolbar(&app, port, text, position, false, None);
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
    /// Mouse-down location (CG global coords), captured to detect drag gestures
    /// on mouse-up. Nothing else is captured here on purpose — see LeftMouseDown.
    down_x: f64,
    down_y: f64,
    /// Selection snapshot taken at mouse-down (worker thread, off the tap):
    /// `None` = still pending, `Some(None)` = no selection, `Some(Some(t))` =
    /// the selected text. Compared on mouse-up to reject stale selections.
    pre_selection: Arc<Mutex<Option<Option<String>>>>,
    /// Focused-window origin at mouse-down (same Option<Option> contract).
    /// A window that moved by mouse-up was DRAGGED (title bar / resize /
    /// space-drag) — a text selection never moves the window. Self-drawn
    /// editors report `AXWindow` for their whole text area, so the role gate
    /// can't reject these drags anymore; this check can, exactly.
    pre_window_origin: Arc<Mutex<Option<Option<(f64, f64)>>>>,
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
            CGEventTapOptions::Default,
            events,
            move |_proxy, event_type, event| {
                handle_system_event(&app, toolbar_port, &click_state, event_type, event)
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
) -> CallbackResult {
    match event_type {
        CGEventType::LeftMouseDown => {
            // Record the down position ONLY — no Accessibility calls here. This
            // tap runs at HeadInsert, so any AX/osascript work in this callback
            // blocks the tap thread and delays every later event (keystrokes
            // included), which is what caused the typing/cursor lag. All slow
            // work is deferred to worker threads.
            let loc = event.location();
            let pre_selection: Arc<Mutex<Option<Option<String>>>> = Arc::new(Mutex::new(None));
            let pre_window_origin: Arc<Mutex<Option<Option<(f64, f64)>>>> = Arc::new(Mutex::new(None));
            if let Ok(mut state) = click_state.lock() {
                *state = Some(ClickState {
                    down_x: loc.x,
                    down_y: loc.y,
                    pre_selection: pre_selection.clone(),
                    pre_window_origin: pre_window_origin.clone(),
                });
            }


            // Snapshot the selection NOW, before the app processes this
            // mouse-down and mutates it — on mouse-up we compare against it so
            // a stale selection (still shown by browsers after a plain click)
            // doesn't pop the toolbar. Runs off the tap thread. The focused
            // window's origin is snapshotted the same way: a window that moved
            // by mouse-up was dragged, not text-selected.
            let app = app.clone();
            thread::spawn(move || {
                if !toolbar_enabled_for_app(&app) || active_toolbar_actions().is_none() {
                    return;
                }
                // Window origin FIRST: even a degenerate AX tree (Sublime —
                // bare window element) answers AXFocusedWindow/AXPosition
                // fast, while the selection read below can hang for the
                // default 6s timeout on such apps. The mouse-up drag check
                // needs the origin captured well before release.
                let origin = unsafe { frontmost_pid() }.and_then(|pid| unsafe {
                    cg_window_origin(pid)
                });
                if let Ok(mut cell) = pre_window_origin.lock() {
                    *cell = Some(origin);
                }

                // Snapshot the selection NOW, before the app processes this
                // mouse-down and mutates it — on mouse-up we compare against it
                // so a stale selection doesn't pop the toolbar.
                let _selection = selection_read_guard();
                let pre = read_selected_text_via_ax().map(|s| s.trim().to_string());
                if let Ok(mut cell) = pre_selection.lock() {
                    *cell = Some(pre);
                }
            });
        }
        CGEventType::LeftMouseUp => {
            let state = click_state.lock().ok().and_then(|mut s| s.take());
            let Some(ClickState { down_x, down_y, pre_selection, pre_window_origin }) = state else {
                return CallbackResult::Keep;
            };


            // Cheap, non-AX work only — see LeftMouseDown. Everything slow runs
            // on a worker thread so the tap never blocks.
            let position = appkit_position_from_event(event);
            let click_count =
                event.get_integer_value_field(EventField::MOUSE_EVENT_CLICK_STATE) as u64;
            // A bare click (no drag, single click) never triggers the toolbar.
            if !is_selection_gesture(down_x, down_y, event) {
                return CallbackResult::Keep;
            }

            let app = app.clone();
            thread::spawn(move || {
                // Potentially slow gating + reads happen off the tap thread.
                if !toolbar_enabled_for_app(&app) {
                    return;
                }
                if active_toolbar_actions().is_none() {
                    return;
                }

                // Clicks on our own UI (helper panels / main window) are
                // interactions, not selection gestures — the fallback's
                // synthetic Cmd+C would land on the still-frontmost source
                // app and beep.
                if position_hits_own_ui(down_x, down_y) {
                    return;
                }
                // Let the app process the mouse up and update its selection. Our
                // tap runs BEFORE the app sees the event (HeadInsert).
                thread::sleep(Duration::from_millis(80));

                // Selection reading is a system-global critical section: the AX
                // client library is not thread-safe and the clipboard
                // borrow/restore must not interleave with another worker.
                let _selection = selection_read_guard();

                // A real selection gesture starts on a text element. Window
                // drags (title bar, toolbar, scroll bar, …) are drag gestures
                // too — gate EVERY path here, including the menu/Cmd+C
                // fallbacks, so they never pop the toolbar.
                if !is_text_area_at_position(down_x, down_y) {
                    return;
                }

                // A moved window between down and up = the press was a window
                // drag (title bar, resize, space-drag) — never a selection,
                // regardless of what the copy tiers would still find from an
                // older selection. `None` (no window / read failed) never
                // blocks; a still-pending snapshot (fast drag before the
                // down-worker's AX round-trip) gets a short grace wait.
                let mut pre_origin = pre_window_origin
                    .lock()
                    .ok()
                    .and_then(|mut s| s.take().flatten());
                if pre_origin.is_none() {
                    for _ in 0..20 {
                        thread::sleep(Duration::from_millis(10));
                        pre_origin = pre_window_origin
                            .lock()
                            .ok()
                            .and_then(|mut s| s.take().flatten());
                        if pre_origin.is_some() {
                            break;
                        }
                    }
                }
                match pre_origin {
                    Some(pre) => {
                        let moved = unsafe { frontmost_pid() }
                            .and_then(|pid| unsafe { cg_window_origin(pid) })
                            .map(|now| (now.0 - pre.0).abs() > 1.0 || (now.1 - pre.1).abs() > 1.0);
                        if moved == Some(true) {
                            log_native("window moved during press — drag, not selection; skipping");
                            return;
                        }
                    }
                    None => {
                        log_native("window-origin snapshot unavailable; drag check skipped");
                    }
                }

                // The selection must be NEW: identical to what was selected
                // before mouse-down means the gesture (click with jitter,
                // window drag) didn't select anything — the app is just still
                // showing the old selection. A multi-click re-selecting the
                // same text is deliberate and still pops.
                let pre = pre_selection
                    .lock()
                    .ok()
                    .and_then(|mut s| s.take().flatten());

                // AX path — only when the click landed on a text element, so we
                // don't read a stale focused selection when clicking chrome.
                if let Some(post) = read_selected_text_via_ax()
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                {
                    if pre.as_deref() == Some(post.as_str()) && click_count < 2 {
                        log_native("AX selection unchanged since mouse-down; skipping");
                        return;
                    }
                    log_native(&format!(
                        "AX selection changed length={}",
                        post.len()
                    ));
                    show_toolbar(&app, toolbar_port, post, position, false, Some((down_x, down_y)));
                    return;
                }

                // Web-area fallback — browsers keep their selection in text
                // markers instead of AXSelectedText (Chrome/Safari/Edge/Arc).
                // Reads the live AX tree; no clipboard involvement.
                if let Some(post) = read_selected_text_via_web_area()
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                {
                    log_native(&format!("web-area selection length={}", post.len()));
                    show_toolbar(&app, toolbar_port, post, position, false, Some((down_x, down_y)));
                    return;
                }

                // Menu fallback — apps AX can't read (Ghostty, Zed, ...).
                // Clipboard-safe: only borrow when non-text-free, restore exactly,
                // and skip unless the pasteboard actually changed (no selection →
                // no popup, no clipboard disturbance).
                let text = read_selected_text_via_menu()
                    .or_else(read_selected_text_via_cmd_c);
                if let Some(t) = text {
                    log_native(&format!("fallback selection length={}", t.len()));
                    show_toolbar(&app, toolbar_port, t, position, false, Some((down_x, down_y)));
                }
            });
        }
        // NOTE: while the native card is up, the helper is the ACTIVE app with
        // a key panel (OS-normal model): arrows/Enter/Tab/Esc travel the
        // standard responder chain inside the helper. This tap no longer
        // intercepts or rewrites any of them — no global key pollution.

        CGEventType::KeyDown if is_translate_shortcut(event) => {
            log_native("shortcut key detected");
            let app = app.clone();
            thread::spawn(move || {
                trigger_popup_with_selection(&app);
            });
        }
        CGEventType::KeyDown if is_copy_command(event) => {
            // User pressed Cmd+C. Record what they copied (fresh for 5s) —
            // the browser fallback when AX/web-area can't read the selection.
            let app = app.clone();
            thread::spawn(move || {
                handle_copy_for_toolbar(&app);
            });
        }
        CGEventType::KeyDown if is_selection_gesture_key(event) => {
            // Keyboard selection (⌘A / ⌘L / ⇧+arrows): same pipeline as a drag
            // selection, minus the mouse-specific gates (no coordinates).
            let position = cursor_position();
            let app = app.clone();
            thread::spawn(move || {
                // Debounce: shift-arrow selections arrive as a stream of key
                // events — wait for the gesture to settle, then read once.
                thread::sleep(Duration::from_millis(150));
                if !toolbar_enabled_for_app(&app) {
                    return;
                }
                if active_toolbar_actions().is_none() {
                    return;
                }
                let _selection = selection_read_guard();
                // Lossless tiers only (AX / web-area): never synthesize Cmd+C
                // on a plain keyboard gesture.
                let text = read_selected_text_via_ax()
                    .map(|s| s.trim().to_string())
                    .filter(|s| !s.is_empty())
                    .or_else(|| {
                        read_selected_text_via_web_area()
                            .map(|s| s.trim().to_string())
                            .filter(|s| !s.is_empty())
                    });
                if let Some(text) = text {
                    log_native(&format!("keyboard selection length={}", text.len()));
                    show_toolbar(&app, toolbar_port, text, position, false, None);
                }
            });
        }
        CGEventType::FlagsChanged => {
            handle_flags_changed(app, event);
        }
        _ => {}
    }

    CallbackResult::Keep
}
/// True when the screen position lands on OUR OWN UI (helper panels or the
/// main window) — clicks there are interactions with this app, not selection
/// gestures in a source app, and must never kick off selection reading (the
/// fallback's synthetic Cmd+C at the still-frontmost source app was the
/// rename double-click's mystery beep).
fn position_hits_own_ui(x: f64, y: f64) -> bool {
    unsafe {
        let system = AXUIElementCreateSystemWide();
        if system.is_null() {
            return false;
        }
        let mut element: AXUIElementRef = ptr::null();
        let result = AXUIElementCopyElementAtPosition(system, x as f32, y as f32, &mut element);
        CFRelease(system as CFTypeRef);
        if result != AX_ERROR_SUCCESS || element.is_null() {
            return false;
        }
        let mut pid: i32 = 0;
        AXUIElementGetPid(element, &mut pid);
        CFRelease(element as CFTypeRef);
        pid == std::process::id() as i32
            || pid == HELPER_PID.load(std::sync::atomic::Ordering::Relaxed)
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
        // NO `AXWindow` here: self-drawn editors report the bare window for
        // their whole text area (Sublime, terminals, some Electron hosts) —
        // blocking it gates out their ONLY path (openclip's default
        // skipRoles excludes it too). Window-background drags stay safe via
        // the selection-gesture check plus the copy tiers' pasteboard-bump
        // guard: no real selection → no toolbar.
        match role.as_deref() {
            Some("AXToolbar") | Some("AXButton") |
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

/// Keyboard selection gestures worth surfacing the toolbar: ⌘A (select all),
/// ⌘L (select address bar / line), and ⇧/⌥⇧/⌘⇧ + arrows/Home/End/PageUp/
/// PageDown. Gesture flags are intersected to the pure modifier bits first —
/// capsLock and device bits (function/numericPad/help) never belong to the
/// gesture (openclip `MacSelectionMonitor.isSelectionTrigger`).
fn is_selection_gesture_key(event: &CGEvent) -> bool {
    let keycode = event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYCODE) as u16;
    let cmd = CGEventFlags::CGEventFlagCommand;
    let shift = CGEventFlags::CGEventFlagShift;
    let alt = CGEventFlags::CGEventFlagAlternate;
    let gesture = event.get_flags() & (cmd | shift | alt);
    if gesture == cmd {
        // kVK_ANSI_A / kVK_ANSI_L — exact ⌘ plus the key, nothing else.
        return keycode == 0x00 || keycode == 0x25;
    }
    if gesture.contains(shift) {
        // left/right/down/up, home, end, page up, page down
        return matches!(keycode, 0x7B..=0x7E | 0x73 | 0x77 | 0x74 | 0x79);
    }
    false
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
    // Capture the write-back target and read the selection BEFORE showing the
    // popup. The popup's makeKeyWindow steals focus from the source app, and
    // every read tier (AX, web-area markers, and the Cmd+C fallback's event
    // target) needs the source app still frontmost — showing first left the
    // shortcut path reading the wrong app (log: "shortcut no selected text").
    capture_selection_target();

    // Serialize with the mouse-up selection worker — see selection_read_guard.
    let _selection = selection_read_guard();

    // Chain: ax-text → ax-web-area → menu/cmd-c → last-copied(5s).
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

    // Browsers: web-area markers (no clipboard).
    let (text, source) = match text {
        Some(t) => (Some(t), source),
        None => match read_selected_text_via_web_area().filter(|s| !s.trim().is_empty()) {
            Some(s) => (Some(s.trim().to_string()), "web-area"),
            None => (None, source),
        },
    };

    // NOTE: no menu/Cmd+C fallback on the shortcut path. Synthesizing keys
    // at an app without a selection lands as an invalid command (the system
    // error beep users heard). Browsers are covered by the fresh-copy
    // fallback below; drag-selection reading keeps its own richer path.


    // Final courtesy: the text the user just Cmd+C'd, if still fresh.
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

    // Selection → native result card streaming the AI run directly (WebView
    // popup_card no longer participates). No selection → native Notes panel:
    // real AppKit rendering, keyboard routed through this tap, and the source
    // app's caret never stops.
    if let Some(selected) = &text {
        show_result_card(app, selected, "translation");
    } else {
        // Cursor sits in an input with nothing selected: open the native card
        // straight onto its Notes tab — ↑/↓ select, Enter injects at the
        // source app's caret (the panel's core purpose).
        show_idle_card(app);
        let _ = send_card_notes(app);
        log_native(&format!("shortcut notes mode (source={})", source));
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

    // Serialize with the selection workers: without this we can snapshot a
    // borrowed (fallback) clipboard value as "user-copied" text while another
    // worker's restore is in flight.
    let _selection = selection_read_guard();

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

/// Serializes every selection read (AX queries + clipboard borrow/restore).
/// The macOS AX client keeps per-process CFDictionary caches that are NOT
/// safe under concurrent calls from multiple threads — two overlapping
/// selection workers corrupt AppKit's internal state and abort the process
/// (SIGABRT: "pointer being freed was not allocated" in CFDictionarySetValue,
/// see crash log lexi-2026-08-25-134724). The clipboard borrow/restore contract
/// also requires mutual exclusion, or two fallbacks interleave and clobber the
/// user's clipboard. Inner read fns assume the CALLER holds this lock.
pub(crate) fn selection_read_guard() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: Mutex<()> = Mutex::new(());
    LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
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

        // Self-selection guard: while the helper's rename editor owns the
        // focused element (double-click → select-all), that text is OUR UI,
        // not a user selection in a source app.
        let mut element_pid: i32 = 0;
        AXUIElementGetPid(focused, &mut element_pid);
        if element_pid == std::process::id() as i32
            || element_pid == HELPER_PID.load(std::sync::atomic::Ordering::Relaxed)
        {
            CFRelease(focused as CFTypeRef);
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

// ---------------------------------------------------------------------------
// Web-area selection reading — browsers (WebKit and Chromium).
//
// Chrome/Safari/Edge/Arc don't expose `AXSelectedText` on their focused
// element; web content keeps its selection in opaque text markers on the
// AXWebArea. Reading it: the focused element's (or the web area's)
// `AXSelectedTextMarkerRange`, resolved through the parameterized
// `AXStringForTextMarkerRange` attribute — no Cmd+C, no clipboard, ~1ms.
// Same technique as openclip's AXWebAreaStrategy.
// ---------------------------------------------------------------------------

/// Re-reads of a web selection that came back empty (the renderer may lag the
/// selection gesture by a frame), and the wait between reads.
const WEB_AREA_SETTLE_ATTEMPTS: usize = 3;
const WEB_AREA_SETTLE_INTERVAL_MS: u64 = 50;
/// Bounded ancestor walk when hunting the containing web area (openclip uses 25).
const WEB_AREA_ANCESTOR_WALK_DEPTH: usize = 25;
/// Bounded child search under the focused window when the focused element has
/// no web-area ancestor (selecting static page text can leave focus at the
/// window level).
const WEB_AREA_CHILD_SEARCH_DEPTH: usize = 6;

/// Read the frontmost browser's selection via text markers. `None` when the
/// app has no web area or the web area exposes no selection.
fn read_selected_text_via_web_area() -> Option<String> {
    unsafe {
        let app = ax_focused_application()?;
        // `focused` is the caller's (not owned by us) until copied; both app
        // and a copied focused element must be released on every exit path.
        let mut focused: AXUIElementRef = ptr::null();
        let result = web_area_selection(app, &mut focused);
        if !focused.is_null() {
            CFRelease(focused as CFTypeRef);
        }
        CFRelease(app as CFTypeRef);
        result
    }
}

unsafe fn web_area_selection(
    app: AXUIElementRef,
    focused_out: &mut AXUIElementRef,
) -> Option<String> {
    // The focused element comes from the application, never the system-wide
    // element — the system-wide focused element is a classic stale-read source.
    let focused = copy_ax_element_attribute(app, "AXFocusedUIElement")?;
    *focused_out = focused;
    let web_area = find_web_area_ancestor(focused)
        .or_else(|| find_web_area_in_focused_window(app))?;
    let selection = read_web_area_selection(focused, web_area);
    CFRelease(web_area as CFTypeRef);
    selection
}

/// Walk up from `element` (bounded) looking for the AXWebArea ancestor
/// (retained). Web content renders under an AXWebArea role in both WebKit
/// (Safari) and Chromium (Chrome/Edge/Arc/Electron).
unsafe fn find_web_area_ancestor(element: AXUIElementRef) -> Option<AXUIElementRef> {
    let mut current = element;
    let mut owned = false;
    for _ in 0..WEB_AREA_ANCESTOR_WALK_DEPTH {
        let Some(parent) = copy_ax_element_attribute(current, "AXParent") else {
            break;
        };
        if owned {
            CFRelease(current as CFTypeRef);
        }
        current = parent;
        owned = true;
        if accessibility_string_attribute(current, "AXRole").as_deref() == Some("AXWebArea") {
            return Some(current);
        }
    }
    if owned {
        CFRelease(current as CFTypeRef);
    }
    None
}

/// Find the focused window's first AXWebArea descendant (retained), searching
/// depth-first and bounded.
unsafe fn find_web_area_in_focused_window(app: AXUIElementRef) -> Option<AXUIElementRef> {
    let window = copy_ax_element_attribute(app, "AXFocusedWindow")?;
    let found = find_web_area_descendant(window, WEB_AREA_CHILD_SEARCH_DEPTH);
    CFRelease(window as CFTypeRef);
    found
}

/// Depth-first search for the first AXWebArea descendant (retained). Every
/// visited child is released exactly once; ownership transfers only to the hit.
unsafe fn find_web_area_descendant(element: AXUIElementRef, depth: usize) -> Option<AXUIElementRef> {
    if depth == 0 {
        return None;
    }
    let mut found: Option<AXUIElementRef> = None;
    for child in ax_children(element) {
        if found.is_some() {
            CFRelease(child as CFTypeRef);
            continue;
        }
        if accessibility_string_attribute(child, "AXRole").as_deref() == Some("AXWebArea") {
            found = Some(child);
            continue;
        }
        if let Some(deeper) = find_web_area_descendant(child, depth - 1) {
            found = Some(deeper);
        }
        CFRelease(child as CFTypeRef);
    }
    found
}

/// Read the web selection, retrying briefly when the renderer hasn't caught up
/// with the gesture yet (empty text right after mouse-up).
unsafe fn read_web_area_selection(
    focused: AXUIElementRef,
    web_area: AXUIElementRef,
) -> Option<String> {
    for attempt in 0..WEB_AREA_SETTLE_ATTEMPTS {
        if attempt > 0 {
            thread::sleep(Duration::from_millis(WEB_AREA_SETTLE_INTERVAL_MS));
        }
        // The marker range lives on the focused element when it carries
        // markers; the web area itself carries it otherwise.
        let marker_range = copy_marker_range(focused).or_else(|| copy_marker_range(web_area));
        let Some(range) = marker_range else {
            continue;
        };
        let attr = CFString::from_static_string("AXStringForTextMarkerRange");
        let mut value: CFTypeRef = ptr::null();
        let result = AXUIElementCopyParameterizedAttributeValue(
            web_area,
            attr.as_concrete_TypeRef(),
            range,
            &mut value,
        );
        CFRelease(range as CFTypeRef);
        if result != AX_ERROR_SUCCESS || value.is_null() {
            continue;
        }
        let wrapped = CFType::wrap_under_create_rule(value);
        if let Some(text) = wrapped.downcast::<CFString>() {
            let text = text.to_string();
            if !text.trim().is_empty() {
                return Some(text);
            }
        }
    }
    None
}

// ---------------------------------------------------------------------------
// Menu-action selection fallback — for apps where AX can't read the selection.
//
// Terminals (Ghostty), custom-rendered editors (Zed) and some Electron apps
// don't expose `AXSelectedText`. To still support them we invoke the app's own
// Edit → Copy menu item via `AXPress` and read the resulting pasteboard.
//
// Safety contract — must never disturb the user's system state:
//   1. Never inject keystrokes (only the app's own menu action) → no stray
//      characters, unlike a synthesized Cmd+C.
//   2. Only borrow the pasteboard when it carries no non-text data (images,
//      files, …), so a user's image/file clipboard can never be clobbered.
//   3. Always restore the pasteboard to its exact pre-call text, or clear it
//      back to empty, when done.
//   4. Guard on pasteboard `changeCount`: if Copy didn't change the pasteboard
//      (no selection / disabled item) → return None (no popup, clipboard restored).
//   5. The auto mouse-up path additionally requires a selection gesture (drag
//      or multi-click) AND that the gesture started on a text element, so bare
//      clicks and window drags never trigger a borrow.
// ---------------------------------------------------------------------------

/// Read the current selection by invoking the frontmost app's Edit → Copy menu
/// item. Returns the selected text without leaving it on the clipboard. `None`
/// if there's no Copy menu, the clipboard is unsafe to borrow, or Copy produced
/// nothing (no selection).
fn read_selected_text_via_menu() -> Option<String> {
    let pre_text = read_pasteboard_string_via_pb();

    if !pasteboard_safe_to_borrow() {
        log_native("menu-read: pasteboard has non-text content; skipping to avoid clobbering");
        return None;
    }

    let app = unsafe { ax_focused_application() };
    let Some(app) = app else {
        log_native("menu-read: no focused application");
        return None;
    };
    // A hung app must never block the worker: bound every AX round-trip
    // against it (openclip AXMenuNavigator sets this before each read).
    unsafe { AXUIElementSetMessagingTimeout(app, 1.5) };
    if let Some(pid) = unsafe { frontmost_pid() } {
        let bundle = unsafe { frontmost_bundle_id() }.unwrap_or_else(|| "?".into());
        log_native(&format!("menu-read: focused app pid={pid} ({bundle})"));
    }

    let result = unsafe { find_copy_menu_item(app) }.and_then(|copy_item| {
        let text = unsafe { perform_menu_copy_and_read(copy_item, pre_text.as_deref()) };
        unsafe { CFRelease(copy_item as CFTypeRef) };
        text
    });

    unsafe { CFRelease(app as CFTypeRef) };
    result
        .filter(|s| !s.trim().is_empty())
        .map(|s| s.trim().to_string())
}

/// Press the Copy menu item, wait for the pasteboard to change, read the new
/// text, then restore the pasteboard. The pasteboard is always restored,
/// whether or not Copy produced anything.
unsafe fn perform_menu_copy_and_read(
    copy_item: AXUIElementRef,
    pre_text: Option<&str>,
) -> Option<String> {
    let count_before = pasteboard_change_count();
    // Bound every AX round-trip against a hung app (openclip sets this on
    // the item before AXPress).
    unsafe { AXUIElementSetMessagingTimeout(copy_item, 1.5) };

    let action = CFString::from_static_string("AXPress");
    let _ = AXUIElementPerformAction(copy_item, action.as_concrete_TypeRef());

    // Copy is async — poll the pasteboard changeCount on the per-app budget
    // (browsers resolve clipboard writes over async IPC and need longer).
    let budget_ms = clipboard_poll_budget_ms();
    let mut bumped = false;
    for _ in 0..(budget_ms / 10).max(1) {
        thread::sleep(Duration::from_millis(10));
        if pasteboard_change_count() > count_before {
            bumped = true;
            break;
        }
    }

    // Read the selection BEFORE restoring (restore overwrites it), after a
    // short settle so a multi-write clipboard update lands fully first.
    let text = if bumped {
        thread::sleep(Duration::from_millis(PASTEBOARD_RESTORE_DELAY_MS));
        read_pasteboard_string_via_pb()
    } else {
        None
    };

    restore_pasteboard(pre_text);

    if !bumped {
        log_native("menu-read: Copy did not change pasteboard (no selection); skipping");
        return None;
    }
    text
}

/// Restore the pasteboard to what `read_pasteboard_string_via_pb` captured: put
/// the original text back, or clear it if it was empty/whitespace.
pub(crate) fn restore_pasteboard(pre_text: Option<&str>) {
    match pre_text.map(str::trim) {
        Some(t) if !t.is_empty() => {
            if let Err(e) = write_clipboard(t) {
                log_native(&format!("menu-read: failed to restore clipboard: {e}"));
            }
        }
        _ => {
            // Was empty (non-text is already gated out) → clear what Copy wrote.
            clear_pasteboard();
        }
    }
}

// ---------------------------------------------------------------------------
// Cmd+C injection fallback (last resort) — FULL modifier sequence.
//
// Used when neither AX nor the menu-action fallback can read the selection
// (apps whose submenu items aren't exposed until the menu is opened — Zed,
// Orca, Ghostty). We synthesize a Cmd+C delivered to the target app.
//
// Why the FULL four-event sequence (not just c-down/c-up with a flag):
//   Cmd-FlagsChanged(down) → c-down → c-up → Cmd-FlagsChanged(up)
// The two FlagsChanged events update the *live* modifier state in the target
// app. Without them, apps that read modifier state (not the event's flag) see
// a bare 'c' — the "ghost c" leak. This is the technique Easydict/KeySender use.
//
// Clipboard safety (same as the menu path): borrow only when free of non-text
// content, restore exactly afterwards, skip unless the pasteboard actually
// changed (no selection → no popup, no disturbance).
// ---------------------------------------------------------------------------

fn read_selected_text_via_cmd_c() -> Option<String> {
    let pre_text = read_pasteboard_string_via_pb();

    if !pasteboard_safe_to_borrow() {
        log_native("cmdc-read: pasteboard has non-text content; skipping to avoid clobbering");
        return None;
    }

    let pid = unsafe { frontmost_pid() };
    let Some(pid) = pid else {
        log_native("cmdc-read: no frontmost pid");
        return None;
    };

    let result = unsafe { post_cmd_c_and_read(pid, pre_text.as_deref()) };
    result
        .filter(|s| !s.trim().is_empty())
        .map(|s| s.trim().to_string())
}

pub(crate) const CMD_KEYCODE: u16 = 0x37; // kVK_Command

/// Post the full Cmd+C sequence, wait for the pasteboard, read, restore.
///
/// Events go to the SESSION tap (not `post_to_pid`), built on a
/// `combinedSessionState` source with the 0x8 hardware bit set — the
/// openclip `SessionEventTapPoster` recipe. Chromium-family and self-drawn
/// editors (Chrome, Electron hosts, Sublime) ignore pid-posted synthetic
/// keyboard events, but session-tap events ride the normal dispatch path
/// and are honored like real keys.
unsafe fn post_cmd_c_and_read(pid: i32, pre_text: Option<&str>) -> Option<String> {
    let count_before = pasteboard_change_count();
    let bundle = frontmost_bundle_id().unwrap_or_else(|| "?".into());
    let cmd = CGEventFlags::CGEventFlagCommand;

    let cmd_down = session_flags_changed_event(CMD_KEYCODE, cmd)?;
    cmd_down.post(CGEventTapLocation::Session);
    let c_down = session_key_event(KeyCode::ANSI_C, true, cmd)?;
    c_down.post(CGEventTapLocation::Session);
    let c_up = session_key_event(KeyCode::ANSI_C, false, cmd)?;
    c_up.post(CGEventTapLocation::Session);
    let cmd_up = session_flags_changed_event(CMD_KEYCODE, CGEventFlags::empty())?;
    cmd_up.post(CGEventTapLocation::Session);

    let budget_ms = clipboard_poll_budget_ms();
    log_native(&format!(
        "cmdc-read: session-tap Cmd+C posted to pid {pid} ({bundle}), poll budget {budget_ms}ms"
    ));

    let mut bumped = false;
    for _ in 0..(budget_ms / 10).max(1) {
        thread::sleep(Duration::from_millis(10));
        if pasteboard_change_count() > count_before {
            bumped = true;
            break;
        }
    }

    let text = if bumped {
        // Give the app's (possibly multi-write) clipboard update a moment to
        // land before reading — restoring immediately races the late writes.
        thread::sleep(Duration::from_millis(PASTEBOARD_RESTORE_DELAY_MS));
        read_pasteboard_string_via_pb()
    } else {
        None
    };

    restore_pasteboard(pre_text);

    if !bumped {
        log_native("cmdc-read: Cmd+C did not change pasteboard (no selection); skipping");
        return None;
    }
    text
}

/// Chromium-family and browser frontmost apps resolve clipboard writes
/// through asynchronous multi-process IPC — they need a longer changeCount
/// poll budget than native apps (openclip PasteboardCopyEngine.pollingTimeout).
fn clipboard_poll_budget_ms() -> u64 {
    let bundle = unsafe { frontmost_bundle_id() }.unwrap_or_default();
    let slow = bundle.starts_with("com.google.Chrome")
        || bundle.starts_with("org.mozilla.")
        || bundle.starts_with("com.apple.Safari")
        || bundle.starts_with("com.microsoft.edgemac")
        || bundle.starts_with("com.brave.")
        || bundle.starts_with("company.thebrowser.")
        || bundle.contains("electron")
        || bundle == "com.goty.ai";
    if slow { 800 } else { 400 }
}

/// How long to let the app's clipboard writes settle before we read and
/// restore (openclip `pasteboardRestoreDelay`).
const PASTEBOARD_RESTORE_DELAY_MS: u64 = 120;

/// A copy-synthesis key event: combinedSessionState source + the 0x8 bit
/// hardware events carry (openclip SessionEventTapPoster's resolvedFlags).
unsafe fn session_key_event(
    keycode: u16,
    key_down: bool,
    flags: CGEventFlags,
) -> Option<CGEvent> {
    let source = CGEventSource::new(CGEventSourceStateID::CombinedSessionState).ok()?;
    let event = CGEvent::new_keyboard_event(source, keycode, key_down).ok()?;
    event.set_flags(flags | CGEventFlags::from_bits_retain(0x8));
    Some(event)
}

/// A copy-synthesis FlagsChanged event on the same session source.
unsafe fn session_flags_changed_event(keycode: u16, flags: CGEventFlags) -> Option<CGEvent> {
    let source = CGEventSource::new(CGEventSourceStateID::CombinedSessionState).ok()?;
    let event = CGEvent::new(source).ok()?;
    event.set_type(CGEventType::FlagsChanged);
    event.set_flags(flags | CGEventFlags::from_bits_retain(0x8));
    event.set_integer_value_field(EventField::KEYBOARD_EVENT_KEYCODE, keycode as i64);
    Some(event)
}

/// A FlagsChanged event — used to press/release a modifier key (here, Cmd) so
/// the target app's live modifier state actually reflects it.
pub(crate) unsafe fn flags_changed_event(keycode: u16, flags: CGEventFlags) -> Option<CGEvent> {
    let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState).ok()?;
    let event = CGEvent::new(source).ok()?;
    event.set_type(CGEventType::FlagsChanged);
    event.set_flags(flags);
    event.set_integer_value_field(EventField::KEYBOARD_EVENT_KEYCODE, keycode as i64);
    Some(event)
}

/// A regular key-down/up event carrying the given modifier flags.
pub(crate) unsafe fn key_event(keycode: u16, key_down: bool, flags: CGEventFlags) -> Option<CGEvent> {
    let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState).ok()?;
    let event = CGEvent::new_keyboard_event(source, keycode, key_down).ok()?;
    event.set_flags(flags);
    Some(event)
}

/// Walk the frontmost app's menu bar; return the (retained) Copy menu item,
/// matched by localized title. `None` if not found.
unsafe fn find_copy_menu_item(app: AXUIElementRef) -> Option<AXUIElementRef> {
    let mut menubar_value: CFTypeRef = ptr::null();
    let mb_attr = CFString::from_static_string("AXMenuBar");
    if AXUIElementCopyAttributeValue(app, mb_attr.as_concrete_TypeRef(), &mut menubar_value)
        != AX_ERROR_SUCCESS
        || menubar_value.is_null()
    {
        log_native("menu-read: app exposes no AXMenuBar");
        return None;
    }
    let menubar = menubar_value as AXUIElementRef;
    let mut menus = ax_children(menubar);
    CFRelease(menubar as CFTypeRef);
    log_native(&format!("menu-read: {} top-level menu(s)", menus.len()));

    // The Edit menu is standardly the 4th top-level menu (index 3) — search
    // it first, then the rest (openclip AXMenuNavigator.findMenuItem).
    if menus.len() > 3 {
        menus.swap(0, 3);
    }

    let mut seen: Vec<String> = Vec::new();
    let found = find_copy_in_menus(&menus, &mut seen, 0);
    for menu in &menus {
        CFRelease(*menu as CFTypeRef);
    }
    match &found {
        Some(_) => log_native("menu-read: Copy menu item located"),
        None => {
            let combined = seen.join(" | ");
            let clipped: String = combined.chars().take(400).collect();
            log_native(&format!(
                "menu-read: Copy not found. item titles seen (truncated): {clipped}"
            ));
        }
    }
    found
}

/// Match by the menu item's action identifier — `copy:` is the standard
/// selector Copy items carry, independent of localization (openclip
/// matches `identifier == "copy:"` first).
unsafe fn is_copy_by_identifier(item: AXUIElementRef) -> bool {
    accessibility_string_attribute(item, "AXIdentifier").map(|id| id == "copy:") == Some(true)
}
/// Recursive depth-first walk of menu items. An item matches when its
/// action identifier is `copy:` (localization-agnostic), its keyboard
/// shortcut is Cmd+C (`AXMenuItemCmdChar == "c"`), or its localized title
/// is a known "Copy" — AND it is enabled (pressing a disabled Copy is a
/// wasted round-trip: no selection). `seen` collects item titles for
/// diagnostics when nothing matches. (openclip AXMenuNavigator parity.)
unsafe fn find_copy_in_menus(
    menus: &[AXUIElementRef],
    seen: &mut Vec<String>,
    depth: u32,
) -> Option<AXUIElementRef> {
    if depth > 8 {
        return None;
    }
    for menu in menus {
        let items = ax_children(*menu);

        // 1. Direct match at this level.
        let mut found_idx: Option<usize> = None;
        for (i, item) in items.iter().enumerate() {
            let title = accessibility_string_attribute(*item, "AXTitle").unwrap_or_default();
            let clean = title.trim().trim_end_matches('…').trim().to_string();
            if !clean.is_empty() && seen.len() < 80 {
                seen.push(clean);
            }
            let enabled = accessibility_bool_attribute(*item, "AXEnabled");
            if found_idx.is_none()
                && enabled.unwrap_or(true)
                && (is_copy_by_identifier(*item)
                    || is_copy_menu_title(&title)
                    || is_copy_by_shortcut(*item))
            {
                found_idx = Some(i);
            }
        }
        if let Some(i) = found_idx {
            let found = items[i];
            for (j, item) in items.iter().enumerate() {
                if j != i {
                    CFRelease(*item as CFTypeRef);
                }
            }
            return Some(found);
        }

        // 2. Recurse into submenus (an item's children can themselves be a menu).
        let mut found: Option<AXUIElementRef> = None;
        for item in &items {
            let sub = ax_children(*item);
            if !sub.is_empty() {
                if let Some(f) = find_copy_in_menus(&sub, seen, depth + 1) {
                    found = Some(f);
                }
                for s in &sub {
                    CFRelease(*s as CFTypeRef);
                }
            }
            if found.is_some() {
                break;
            }
        }
        for item in &items {
            CFRelease(*item as CFTypeRef);
        }
        if found.is_some() {
            return found;
        }
    }
    None
}

/// Match a menu item whose shortcut is Cmd+C, regardless of its localized title.
unsafe fn is_copy_by_shortcut(item: AXUIElementRef) -> bool {
    accessibility_string_attribute(item, "AXMenuItemCmdChar")
        .map(|c| c == "c" || c == "C")
        .unwrap_or(false)
}

/// Localized titles for the Copy menu item. Match is exact after trimming a
/// trailing ellipsis (some apps render "Copy…"). Add locales as needed.
fn is_copy_menu_title(title: &str) -> bool {
    let t = title.trim_end_matches('…').trim();
    matches!(
        t,
        "Copy" | "复制" | "拷贝" | "拷貝" | "複製" | "Copier" | "Kopieren"
            | "Copiar" | "Copia" | "Копировать" | "コピー"
    )
}


/// Whether a mouse-up looks like a selection: the pointer dragged more than a
/// few pixels, or it was a double/triple click (word / line select).
fn is_selection_gesture(down_x: f64, down_y: f64, up: &CGEvent) -> bool {
    let click_state = up.get_integer_value_field(EventField::MOUSE_EVENT_CLICK_STATE) as i64;
    if click_state >= 2 {
        return true;
    }
    let loc = up.location();
    let dx = loc.x - down_x;
    let dy = loc.y - down_y;
    (dx * dx + dy * dy) > 25.0 // > ~5px
}

/// Whether the general pasteboard is safe to temporarily borrow: it must carry
/// no non-text data (images, files, …) that we couldn't faithfully restore.
pub(crate) fn pasteboard_safe_to_borrow() -> bool {
    unsafe {
        let pool = new_autorelease_pool();
        let safe = pasteboard_has_only_text_types();
        drain_autorelease_pool(pool);
        safe
    }
}

unsafe fn pasteboard_has_only_text_types() -> bool {
    let pb = pasteboard_object();
    if pb.is_null() {
        return true;
    }
    let sel = sel_registerName(b"types\0".as_ptr() as *const i8);
    // NSArray* (toll-free-bridged with CFArrayRef); autoreleased → pool required.
    let types = objc_msgSend(pb, sel) as *const std::ffi::c_void;
    if types.is_null() {
        return true;
    }
    let count = CFArrayGetCount(types);
    let mut safe = true;
    for i in 0..count {
        let t = CFArrayGetValueAtIndex(types, i) as CFStringRef;
        if t.is_null() {
            continue;
        }
        let uti = CFString::wrap_under_get_rule(t).to_string();
        if looks_like_non_text_uti(&uti) {
            safe = false;
            break;
        }
    }
    safe
}

fn looks_like_non_text_uti(uti: &str) -> bool {
    let u = uti.to_ascii_lowercase();
    u == "public.tiff"
        || u == "public.png"
        || u == "public.jpeg"
        || u == "public.jpeg-2000"
        || u == "public.gif"
        || u == "public.bmp"
        || u == "public.image"
        || u == "public.pdf"
        || u == "com.adobe.pdf"
        || u == "public.file-url"
        || u == "nsfilenamespboardtype"
        || u == "com.apple.pasteboard.promised-file-url"
        || u == "public.movie"
        || u == "public.audio"
        || u.ends_with(".png")
        || u.ends_with(".tiff")
        || u.ends_with(".tif")
        || u.ends_with(".jpg")
        || u.ends_with(".jpeg")
        || u.ends_with(".pdf")
        || u.ends_with(".gif")
        || u.ends_with(".mov")
        || u.ends_with(".mp4")
}

/// Clear the general pasteboard (used to restore an originally-empty board).
fn clear_pasteboard() {
    unsafe {
        let pool = new_autorelease_pool();
        let pb = pasteboard_object();
        if !pb.is_null() {
            let sel = sel_registerName(b"clearContents\0".as_ptr() as *const i8);
            objc_msgSend(pb, sel);
        }
        drain_autorelease_pool(pool);
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
pub(crate) unsafe fn pasteboard_change_count() -> isize {
    let pb = pasteboard_object();
    if pb.is_null() {
        return 0;
    }
    let sel = sel_registerName(b"changeCount\0".as_ptr() as *const i8);
    objc_msgSend(pb, sel) as isize
}

/// Write plain text to the general pasteboard via `pbcopy` — same rationale
/// as the pbpaste reader: direct ObjC string writes on background threads have
/// a crash history, while pbcopy is simple and safe.
fn write_pasteboard_string_via_pb(text: &str) {
    use std::io::Write;
    use std::process::{Command, Stdio};
    if let Ok(mut child) = Command::new("pbcopy")
        .env("LANG", "en_US.UTF-8")
        .stdin(Stdio::piped())
        .spawn()
    {
        if let Some(stdin) = child.stdin.as_mut() {
            let _ = stdin.write_all(text.as_bytes());
        }
        let _ = child.wait();
    }
}

/// Read the current UTF-8 plain-text contents of the pasteboard via `pbpaste`.
/// Avoids direct ObjC `stringForType:` on background threads — that path was
/// crashing the process (autoreleased NSString + reference-count subtleties).
/// pbpaste is ~30-80ms, fine for our 150ms-delayed read.
pub(crate) fn read_pasteboard_string_via_pb() -> Option<String> {
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

pub(crate) fn write_clipboard(text: &str) -> Result<(), String> {
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

pub(crate) fn forward_card_event(
    run_id: &str,
    chunk: Option<&str>,
    done: bool,
    error: Option<&str>,
    translation_json: Option<&str>,
    saved: bool,
) {
    let up = CARD_UP.load(std::sync::atomic::Ordering::Relaxed);
    if !up || done {
        log_native(&format!(
            "card-event: run={run_id} done={done} up={up} port={:?} chunk_len={}",
            toolbar_port(),
            chunk.map(str::len).unwrap_or(0)
        ));
    }
    if !up {
        return;
    }
    let Some(port) = toolbar_port() else { return };
    let payload = serde_json::json!({
        "runId": run_id,
        "chunk": chunk,
        "done": done,
        "error": error,
        "translationJson": translation_json,
        "saved": saved,
    });
    if let Ok(body) = serde_json::to_string(&payload) {
        if let Err(err) = post_to_helper(port, "/result-event", &body) {
            log_native(&format!("card-event: post failed: {err}"));
        }
    }
}

fn show_toolbar(
    _app: &tauri::AppHandle,
    toolbar_port: u16,
    text: String,
    position: CursorPosition,
    pending: bool,
    drag_origin: Option<(f64, f64)>,
) {
    capture_selection_target();
    let Some(actions) = active_toolbar_actions() else {
        log_native("toolbar show ignored disabled or empty actions");
        return;
    };

    // Down coordinates arrive in CG space (top-left origin); flip to the
    // AppKit space the helper positions in, same as `appkit_position_from_event`.
    let primary_height = CGDisplay::main().bounds().size.height as f64;
    let payload = ToolbarShowPayload {
        text,
        x: position.x,
        y: position.y,
        down_x: drag_origin.map(|(x, _)| x as i32),
        down_y: drag_origin.map(|(_, y)| (primary_height - y) as i32),
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
    // The helper reports its own panel dismissal (outside click) so the tap's
    // NOTES_UP flag never goes stale and swallows keys with no panel visible.
    if action.action == "notes-hidden" {
        mark_notes_hidden();
        return Ok(());
    }
    // Row click on the native notes panel: select that row and run the same
    // Enter pipeline (insert at the source app's caret).
    if action.action == "notes-click" {
        if let Ok(id) = action.text.trim().parse::<i64>() {
            NOTES_SELECTED_NOTE_ID.store(id, std::sync::atomic::Ordering::Relaxed);
            thread::spawn(notes_enter);
        }
        return Ok(());
    }
    // Native card lifecycle: the helper reports dismissal / run clears so
    // CARD_UP never goes stale and swallows later stream events.
    if action.action == "card-hidden" || action.action == "card-cleared" {
        CARD_UP.store(false, std::sync::atomic::Ordering::Relaxed);
        return Ok(());
    }
    // Manual input surface: open the card on AiForm + IdleState (no run).
    if action.action == "card-input-mode" {
        show_idle_card(app);
        return Ok(());
    }
    // Save button on a finished run: text is the run's translation JSON
    // (word/translation/pos/definition/example) plus the selected entryType.
    if action.action == "save-vocab" {
        return save_vocab_action(app, &action.text);
    }
    // AiForm submit: text is JSON {kind: "feature"|"tool", id, text}.
    if action.action == "card-input" {
        return card_input_action(app, &action.text);
    }
    // Panel tab data: notes list / next review word. The helper requests on
    // tab switch; Rust owns the database.
    // Notes tab row actions: insert at the source caret / delete the note.
    if action.action == "note-insert" {
        let text = action.text.clone();
        tauri::async_runtime::spawn(async move {
            let _ = crate::text_injection::insert_at_focus(text.clone());
        });
        return Ok(());
    }
    if action.action == "note-rename" {
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(&action.text) {
            if let (Some(id), Some(name)) = (value["id"].as_i64(), value["name"].as_str()) {
                let trimmed = name.trim();
                if !trimmed.is_empty() {
                    let _ = sqlite_query_json(
                        app,
                        &format!(
                            "UPDATE notes SET name = '{}' WHERE id = {id};",
                            trimmed.replace('\'', "''")
                        ),
                    );
                    let _ = app.emit("lexi://notes-changed", ());
                }
            }
        }
        return send_card_notes(app);
    }
    if action.action == "note-tag" {
        // text = "<note_id>|<tag_name>"; empty tag name clears the tag.
        if let Some((id, name)) = action.text.split_once('|') {
            if let Ok(id) = id.trim().parse::<i64>() {
                let tag = name.trim().replace('\'', "''");
                if tag.is_empty() {
                    let _ = sqlite_query_json(
                        app,
                        &format!("DELETE FROM note_tags WHERE note_id = {id};"),
                    );
                } else {
                    let _ = sqlite_query_json(
                        app,
                        &format!("INSERT OR IGNORE INTO tags (name) VALUES ('{tag}');"),
                    );
                    // One visible tag per note: replace rather than add.
                    let _ = sqlite_query_json(
                        app,
                        &format!("DELETE FROM note_tags WHERE note_id = {id};"),
                    );
                    let _ = sqlite_query_json(
                        app,
                        &format!(
                            "INSERT INTO note_tags (note_id, tag_id) \
                             SELECT {id}, id FROM tags WHERE name = '{tag}';"
                        ),
                    );
                }
                let _ = app.emit("lexi://notes-changed", ());
            }
        }
        return send_card_notes(app);
    }
    if action.action == "note-delete" {
        if let Ok(id) = action.text.trim().parse::<i64>() {
            let _ = sqlite_query_json(app, &format!("DELETE FROM notes WHERE id = {id};"));
            let _ = app.emit("lexi://notes-changed", ());
        }
        return send_card_notes(app);
    }

    if action.action == "card-key" {
        return Ok(());
    }
    if action.action == "panel-notes" {
        return send_card_notes(app);
    }
    if action.action == "panel-review" {
        send_next_review_word(app);
        return Ok(());
    }
    if action.action == "panel-translate" {
        return Ok(());
    }
    if action.action == "review-grade" {
        return apply_review_grade(app, &action.text);
    }
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
        // Features (AI): stream into the native result card
        _ => {
            show_result_card(app, &text, action_id);
            Ok(())
        }
    }
}
/// Notes tab: latest 50 notes, pushed to the card for browsing/copying.
fn send_card_notes(app: &tauri::AppHandle) -> Result<(), String> {
    let rows = sqlite_query_json(
        app,
        "SELECT n.id, IFNULL(n.name, '') AS name, n.content, \
         (SELECT GROUP_CONCAT(t.name) FROM note_tags nt JOIN tags t ON t.id = nt.tag_id WHERE nt.note_id = n.id) AS tags \
         FROM notes n ORDER BY n.created_at DESC, n.id DESC LIMIT 50;",
    )
    .unwrap_or_else(|| "[]".to_string());
    // Map rows by hand: sqlite's GROUP_CONCAT yields NULL (no tags) or a
    // comma string — neither deserializes into Vec<String>, and a derive
    // round-trip would fail the whole batch into an empty list.
    if let Ok(values) = serde_json::from_str::<Vec<serde_json::Value>>(&rows) {
        let parsed: Vec<NoteRow> = values
            .iter()
            .map(|row| NoteRow {
                id: row["id"].as_i64(),
                name: row["name"].as_str().unwrap_or("").to_string(),
                content: row["content"].as_str().unwrap_or("").to_string(),
                tags: row["tags"]
                    .as_str()
                    .map(|joined| {
                        joined
                            .split(',')
                            .map(str::trim)
                            .filter(|t| !t.is_empty())
                            .map(str::to_string)
                            .collect()
                    })
                    .unwrap_or_default(),
            })
            .collect();
        if let Ok(mut cell) = NOTES_SNAPSHOT.lock() {
            *cell = parsed;
        }
        NOTES_SELECTED_NOTE_ID.store(-1, std::sync::atomic::Ordering::Relaxed);
    }
    // The tag picker lists every CONFIGURED tag (tags table), not just the
    // ones already bound to a note — the snapshot GROUP_CONCAT misses the
    // unbound ones.
    let all_tags = sqlite_query_json(app, "SELECT name FROM tags ORDER BY name;")
        .and_then(|json| serde_json::from_str::<Vec<serde_json::Value>>(&json).ok())
        .map(|values| {
            values
                .iter()
                .filter_map(|v| v["name"].as_str().map(str::to_string))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let Some(port) = toolbar_port() else { return Ok(()) };
    if let Ok(cell) = NOTES_SNAPSHOT.lock() {
        if let Ok(serialized) = serde_json::to_string(&*cell) {
            if let Ok(tags_json) = serde_json::to_string(&all_tags) {
                let body = format!("{{\"notes\":{serialized},\"allTags\":{tags_json}}}");
                let _ = post_to_helper(port, "/card-notes", &body);
            }
        }
    }
    Ok(())
}

/// Review tab: one due word at a time (WebView ReviewPanel parity).
fn send_next_review_word(app: &tauri::AppHandle) {
    let rows = sqlite_query_json(
        app,
        "SELECT id, word, IFNULL(translation, '') AS translation, IFNULL(pos, '') AS pos, IFNULL(entry_type, 'word') AS entry_type FROM words WHERE status != 'mastered' AND (next_review IS NULL OR next_review <= date('now')) ORDER BY RANDOM() LIMIT 1;",
    )
    .unwrap_or_else(|| "[]".to_string());
    let Some(port) = toolbar_port() else { return };
    // Empty array means "nothing due" — send word: null.
    let word = if rows == "[]" { "null".to_string() } else { rows.trim_start_matches('[').trim_end_matches(']').to_string() };
    let _ = post_to_helper(port, "/card-review", &format!("{{\"word\":{word}}}"));
}

/// SM-2 scheduling (lib/sm2.ts parity) + persist + advance to the next word.
fn apply_review_grade(app: &tauri::AppHandle, text: &str) -> Result<(), String> {
    let Ok(payload) = serde_json::from_str::<serde_json::Value>(text) else {
        return Err("invalid review payload".into());
    };
    let id = payload["id"].as_i64().unwrap_or(0);
    let rating = payload["rating"].as_str().unwrap_or("good").to_string();
    if id <= 0 {
        return Err("invalid word id".into());
    }

    let row = sqlite_query_json(
        app,
        &format!("SELECT review_count, ease_factor, interval FROM words WHERE id = {id};"),
    )
    .and_then(|json| serde_json::from_str::<serde_json::Value>(&json).ok())
    .and_then(|v| v.as_array().and_then(|a| a.first().cloned()));
    let Some(row) = row else {
        return Err("word not found".into());
    };

    let quality: f64 = match rating.as_str() {
        "again" => 2.0,
        "hard" => 3.0,
        "easy" => 5.0,
        _ => 4.0,
    };
    let ease = row["ease_factor"].as_f64().unwrap_or(2.5);
    let interval = row["interval"].as_i64().unwrap_or(0);
    let count = row["review_count"].as_i64().unwrap_or(0);

    let next_ease = ((ease + (0.1 - (5.0 - quality) * (0.08 + (5.0 - quality) * 0.02))).max(1.3) * 100.0).round() / 100.0;
    let next_interval: i64 = if quality < 3.0 || rating == "again" {
        1
    } else if rating == "hard" {
        ((interval as f64) * 1.2).ceil().max(1.0) as i64
    } else if count == 0 {
        if rating == "easy" { 4 } else { 1 }
    } else if count == 1 {
        if rating == "easy" { 8 } else { 6 }
    } else {
        ((interval as f64) * next_ease).ceil() as i64
    };
    let next_count = count + 1;
    let status = if rating == "again" || !(next_count >= 4 && next_interval >= 21) {
        "learning"
    } else {
        "mastered"
    };
    let next_review = iso_date_plus_days(next_interval);

    let _ = sqlite_query_json(
        app,
        &format!(
            "UPDATE words SET status = '{status}', review_count = {next_count}, next_review = '{next_review}', ease_factor = {next_ease}, interval = {next_interval} WHERE id = {id};"
        ),
    );
    let _ = app.emit("lexi://words-changed", ());
    send_next_review_word(app);
    Ok(())
}

/// ISO date (YYYY-MM-DD) `days` from today, epoch-days → civil (Hinnant).
fn iso_date_plus_days(days: i64) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let z = now.div_euclid(86400) + days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}")
}

/// Save button on the native card: persist the run's translation JSON with
/// the entry type the user picked on the card (WebView EntryTypeTags parity).
fn save_vocab_action(app: &tauri::AppHandle, text: &str) -> Result<(), String> {
    let Ok(payload) = serde_json::from_str::<serde_json::Value>(text) else {
        return Err("invalid save payload".into());
    };
    let field = |key: &str| payload[key].as_str().unwrap_or("").to_string();
    let word = field("word");

    if word.trim().is_empty() {
        return Err("empty word".into());
    }
    let entry_type = field("entryType");
    let entry_type = if entry_type.is_empty() { "word".to_string() } else { entry_type };
    save_word_entry(
        &word,
        &field("translation"),
        &field("pos"),
        &field("definition"),
        &field("example"),
        &entry_type,
    );
    let _ = app.emit("lexi://words-changed", ());
    Ok(())
}

/// AiForm submit from the native card: run a feature (empty id = the first
/// enabled feature) or a toolbar tool against the typed text.
fn card_input_action(app: &tauri::AppHandle, text: &str) -> Result<(), String> {
    let Ok(payload) = serde_json::from_str::<serde_json::Value>(text) else {
        return Err("invalid input payload".into());
    };
    let kind = payload["kind"].as_str().unwrap_or("feature");
    let id = payload["id"].as_str().unwrap_or("").to_string();
    let input = payload["text"].as_str().unwrap_or("").trim().to_string();
    if input.is_empty() {
        return Err("empty input".into());
    }

    if kind == "tool" {
        let app_handle = app.clone();
        tauri::async_runtime::spawn(async move {
            if let Err(e) = crate::commands::tools::execute_tool(app_handle, id, input).await {
                eprintln!("[card] tool failed: {e}");
            }
        });
        return Ok(());
    }

    let feature_id = if id.is_empty() {
        let Some(rows) = sqlite_query_json(
            app,
            "SELECT id FROM ai_features WHERE enabled = 1 ORDER BY sort_order LIMIT 1;",
        ) else {
            return Err("no enabled feature".into());
        };
        serde_json::from_str::<serde_json::Value>(&rows)
            .ok()
            .and_then(|v| v.as_array().and_then(|a| a.first()).cloned())
            .and_then(|row| row["id"].as_str().map(str::to_string))
            .unwrap_or_default()
    } else {
        id
    };
    if feature_id.is_empty() {
        return Err("no enabled feature".into());
    }
    show_result_card(app, &input, &feature_id);
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

pub(crate) fn do_handoff(text: &str, target_app: &str) -> Result<(), String> {
    let app = if target_app.is_empty() { "ChatGPT" } else { target_app };
    log_native(&format!("handoff: target={}, text_len={}", app, text.len()));
    // Activate the target app natively (no osascript: no quoting pitfalls — the
    // old script broke on any newline in the text — and no fixed 1s delay),
    // wait for it to take the front, then paste through the pasteboard lease:
    // the user's clipboard is restored afterwards.
    let Some(pid) = text_injection::activate_app_by_bundle_id(app) else {
        return Err(format!("App \"{app}\" is not running."));
    };
    if !text_injection::wait_for_frontmost(pid) {
        return Err(format!("Could not bring \"{app}\" to the front."));
    }
    text_injection::paste_text(pid, text).map(|_| ())
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

fn launch_helper(app: &tauri::AppHandle, action_port: u16, toolbar_port: u16) -> anyhow::Result<()> {
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
    if let Ok(child) = Command::new(&helper_bin)
        .arg("--action-port")
        .arg(action_port.to_string())
        .arg("--toolbar-port")
        .arg(toolbar_port.to_string())
        .spawn()
    {
        HELPER_PID.store(child.id() as i32, std::sync::atomic::Ordering::Relaxed);
    }

    eprintln!("[toolbar] helper launch attempted: action={action_port}, toolbar={toolbar_port}");
    log_native(&format!("helper launch attempted, action={action_port}, toolbar={toolbar_port}"));
    Ok(())
}

fn helper_app_path(app: &tauri::AppHandle) -> anyhow::Result<PathBuf> {
    if let Ok(resource_dir) = app.path().resource_dir() {
        let bundled = resource_dir.join("native/LexiSelectionHelper.app");
        if bundled.exists() {
            return Ok(bundled);
        }
    }

    Ok(env::current_dir()?.join("native/LexiSelectionHelper.app"))
}

/// The helper renders the toolbar, notes panel and result card. If it dies
/// (crash, OOM, user kill), everything native silently disappears until the
/// app restarts. Probe the toolbar port and relaunch when it goes away; the
/// helper's own terminateOlderHelperInstances keeps a double-launch
/// self-consistent.
fn spawn_helper_watchdog(app: tauri::AppHandle, action_port: u16, toolbar_port: u16) {
    thread::spawn(move || {
        let mut last_launch = Instant::now();
        loop {
            thread::sleep(Duration::from_secs(10));
            if TcpStream::connect((IPC_HOST, toolbar_port)).is_ok() {
                continue;
            }
            // A freshly launched helper needs a moment to bind — don't
            // stampede it with repeat launches during its startup window.
            if last_launch.elapsed() < Duration::from_secs(30) {
                continue;
            }
            log_native("watchdog: helper unreachable, relaunching");
            if let Err(error) = launch_helper(&app, action_port, toolbar_port) {
                log_native(&format!("watchdog: relaunch failed: {error}"));
            } else {
                // The relaunched helper comes up with its default theme —
                // re-push the cached one once it binds.
                for _ in 0..30 {
                    if TcpStream::connect((IPC_HOST, toolbar_port)).is_ok() {
                        break;
                    }
                    thread::sleep(Duration::from_millis(500));
                }
                push_theme_to_helper(toolbar_port);
            }
            last_launch = Instant::now();
        }
    });
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

pub(crate) fn log_native(message: &str) {
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
extern "C" {
    fn CGPreflightListenEventAccess() -> bool;
    fn CGRequestListenEventAccess() -> bool;
    fn CGPreflightPostEventAccess() -> bool;
    fn CGRequestPostEventAccess() -> bool;
}
