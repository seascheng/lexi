use crate::cursor::{cursor_position, CursorPosition};
use core_foundation::array::CFArray;
use core_foundation::base::{CFRelease, CFType, CFTypeRef, TCFType};
use core_foundation::dictionary::CFDictionary;
use core_foundation::runloop::CFRunLoop;
use core_foundation::string::{CFString, CFStringRef};
use core_graphics::event::{
    CGEvent, CGEventFlags, CGEventTap, CGEventTapLocation, CGEventTapOptions, CGEventTapPlacement,
    CGEventType, CallbackResult, EventField, KeyCode,
};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use core_graphics::geometry::CGRect;
use core_graphics::window::{create_description_from_array, kCGWindowBounds, CGWindowID};
use serde::{Deserialize, Serialize};
use std::env;
use std::fs::OpenOptions;
use std::io::{ErrorKind, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::ptr;
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tauri::{Emitter, LogicalPosition, LogicalSize, Manager};

const DEFAULT_POPUP_SIZE: f64 = 360.0;
const IPC_HOST: &str = "127.0.0.1";
const LOG_PATH: &str = "/tmp/englist-native-toolbar.log";
const SELECTION_DRAG_THRESHOLD: f64 = 6.0;
const WINDOW_MOVE_THRESHOLD: f64 = 4.0;
const SELECTION_COPY_ATTEMPTS: usize = 2;
const AX_ERROR_SUCCESS: i32 = 0;

type AXUIElementRef = *const std::ffi::c_void;

static TOOLBAR_PORT: OnceLock<Mutex<Option<u16>>> = OnceLock::new();
static TOOLBAR_ACTIONS: OnceLock<Mutex<Vec<ToolbarActionItem>>> = OnceLock::new();

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

#[derive(Clone, Copy)]
struct MouseDownState {
    x: f64,
    y: f64,
    dragged: bool,
    started_at: Instant,
    window: Option<WindowSnapshot>,
    window_chrome: bool,
}

#[derive(Clone, Copy)]
struct WindowSnapshot {
    id: CGWindowID,
    bounds: CGRect,
}

pub fn setup_native_toolbar(app: &tauri::App) -> anyhow::Result<()> {
    log_native("setup native toolbar");
    request_system_permissions();

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
    spawn_selection_monitor(app_handle, toolbar_port);
    Ok(())
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

    post_to_helper(port, "/theme", &body)
        .map_err(|error| format!("Could not send toolbar theme: {error}"))
}

#[tauri::command]
pub fn set_native_toolbar_actions(actions: Vec<ToolbarActionItem>) -> Result<(), String> {
    let mut current = TOOLBAR_ACTIONS
        .get_or_init(|| Mutex::new(default_toolbar_actions()))
        .lock()
        .map_err(|_| "native toolbar actions are unavailable".to_string())?;
    *current = normalized_toolbar_actions(actions);
    Ok(())
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

    if normalized.is_empty() {
        default_toolbar_actions()
    } else {
        normalized
    }
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

fn spawn_selection_monitor(app: tauri::AppHandle, toolbar_port: u16) {
    thread::spawn(move || {
        let mouse_down = Arc::new(Mutex::new(None::<MouseDownState>));
        let events = vec![
            CGEventType::LeftMouseDown,
            CGEventType::LeftMouseDragged,
            CGEventType::LeftMouseUp,
            CGEventType::KeyDown,
        ];

        let result = CGEventTap::with_enabled(
            CGEventTapLocation::HID,
            CGEventTapPlacement::HeadInsertEventTap,
            CGEventTapOptions::ListenOnly,
            events,
            move |_proxy, event_type, event| {
                handle_system_event(&app, toolbar_port, &mouse_down, event_type, event);
                CallbackResult::Keep
            },
            CFRunLoop::run_current,
        );

        if result.is_err() {
            log_native("event tap install failed");
            eprintln!("Could not install Englist system event tap. Grant Input Monitoring to Englist Tool.app and restart.");
            open_privacy_settings("Privacy_ListenEvent");
        } else {
            log_native("event tap stopped");
        }
    });
}

fn handle_system_event(
    app: &tauri::AppHandle,
    toolbar_port: u16,
    mouse_down: &Arc<Mutex<Option<MouseDownState>>>,
    event_type: CGEventType,
    event: &CGEvent,
) {
    match event_type {
        CGEventType::LeftMouseDown => {
            remember_mouse_down(mouse_down, event);
        }
        CGEventType::LeftMouseDragged => mark_mouse_dragged(mouse_down, event),
        CGEventType::LeftMouseUp => {
            if !looks_like_selection(mouse_down, event) {
                return;
            }

            let position = appkit_position_from_event(event);
            thread::spawn(move || match read_selected_text_from_clipboard_probe() {
                Ok(Some(text)) => {
                    log_native(&format!("selected text captured length={}", text.len()));
                    show_toolbar(toolbar_port, text, position, false);
                }
                Ok(None) => {
                    log_native("selection probe returned empty");
                }
                Err(error) => {
                    log_native(&format!("selection probe failed: {error}"));
                    eprintln!("Could not read selected text: {error}");
                }
            });
        }
        CGEventType::KeyDown if is_translate_shortcut(event) => {
            let app = app.clone();
            thread::spawn(move || {
                thread::sleep(Duration::from_millis(35));
                match read_selected_text_from_clipboard_probe() {
                    Ok(Some(text)) => {
                        let _ = open_popup_with_feature(&app, text, "translation");
                    }
                    Ok(None) => {}
                    Err(error) => eprintln!("Could not read selected text for shortcut: {error}"),
                }
            });
        }
        _ => {}
    }
}

fn remember_mouse_down(mouse_down: &Arc<Mutex<Option<MouseDownState>>>, event: &CGEvent) {
    let location = event.location();
    if let Ok(mut state) = mouse_down.lock() {
        *state = Some(MouseDownState {
            x: location.x,
            y: location.y,
            dragged: false,
            started_at: Instant::now(),
            window: window_snapshot_from_event(event),
            window_chrome: pointer_is_on_window_chrome(event),
        });
    }
}

fn mark_mouse_dragged(mouse_down: &Arc<Mutex<Option<MouseDownState>>>, event: &CGEvent) {
    let location = event.location();
    if let Ok(mut state) = mouse_down.lock() {
        let Some(start) = state.as_mut() else {
            return;
        };

        let delta_x = location.x - start.x;
        let delta_y = location.y - start.y;
        let distance = (delta_x * delta_x + delta_y * delta_y).sqrt();
        if distance >= SELECTION_DRAG_THRESHOLD {
            start.dragged = true;
        }
    }
}

fn looks_like_selection(mouse_down: &Arc<Mutex<Option<MouseDownState>>>, event: &CGEvent) -> bool {
    let Some(start) = mouse_down.lock().ok().and_then(|mut state| state.take()) else {
        log_native("mouse up ignored no mouse down state");
        return false;
    };

    if start.window_chrome {
        log_native("mouse up ignored window chrome drag candidate");
        return false;
    }

    if window_changed_since_mouse_down(&start) {
        log_native("mouse up ignored window moved during drag");
        return false;
    }

    let click_count = event.get_integer_value_field(EventField::MOUSE_EVENT_CLICK_STATE);
    if click_count >= 2 {
        log_native(&format!(
            "selection candidate double click count={click_count}"
        ));
        return true;
    }

    let location = event.location();
    let delta_x = location.x - start.x;
    let delta_y = location.y - start.y;
    let distance = (delta_x * delta_x + delta_y * delta_y).sqrt();
    let elapsed = start.started_at.elapsed();
    let is_selection = start.dragged
        || (distance >= SELECTION_DRAG_THRESHOLD && elapsed >= Duration::from_millis(80));
    log_native(&format!(
        "mouse up distance={:.1} elapsed={}ms dragged={} selection={}",
        distance,
        elapsed.as_millis(),
        start.dragged,
        is_selection
    ));

    is_selection
}

fn window_snapshot_from_event(event: &CGEvent) -> Option<WindowSnapshot> {
    let window_id = event_window_id(event)?;
    let bounds = window_bounds(window_id)?;
    Some(WindowSnapshot {
        id: window_id,
        bounds,
    })
}

fn event_window_id(event: &CGEvent) -> Option<CGWindowID> {
    let id = event
        .get_integer_value_field(
            EventField::MOUSE_EVENT_WINDOW_UNDER_MOUSE_POINTER_THAT_CAN_HANDLE_THIS_EVENT,
        )
        .max(event.get_integer_value_field(EventField::MOUSE_EVENT_WINDOW_UNDER_MOUSE_POINTER));

    (id > 0).then_some(id as CGWindowID)
}

fn window_bounds(window_id: CGWindowID) -> Option<CGRect> {
    let window_ids = CFArray::from_copyable(&[window_id]);
    let descriptions = create_description_from_array(window_ids)?;
    let description = descriptions.get(0)?;
    let bounds_key = unsafe { CFString::wrap_under_get_rule(kCGWindowBounds) };
    let bounds_value = description.find(&bounds_key)?;
    let bounds_dictionary = bounds_value.downcast::<CFDictionary>()?;

    CGRect::from_dict_representation(&bounds_dictionary)
}

fn window_changed_since_mouse_down(start: &MouseDownState) -> bool {
    let Some(window) = start.window else {
        return false;
    };
    let Some(current_bounds) = window_bounds(window.id) else {
        return false;
    };

    rect_delta(window.bounds, current_bounds) >= WINDOW_MOVE_THRESHOLD
}

fn rect_delta(start: CGRect, current: CGRect) -> f64 {
    let origin_delta_x = current.origin.x - start.origin.x;
    let origin_delta_y = current.origin.y - start.origin.y;
    let size_delta_width = current.size.width - start.size.width;
    let size_delta_height = current.size.height - start.size.height;

    origin_delta_x
        .abs()
        .max(origin_delta_y.abs())
        .max(size_delta_width.abs())
        .max(size_delta_height.abs())
}

fn pointer_is_on_window_chrome(event: &CGEvent) -> bool {
    let location = event.location();
    let Some((role, subrole)) = accessibility_role_at_position(location.x, location.y) else {
        return false;
    };

    is_window_chrome_role(role.as_deref(), subrole.as_deref())
}

fn accessibility_role_at_position(x: f64, y: f64) -> Option<(Option<String>, Option<String>)> {
    unsafe {
        let system = AXUIElementCreateSystemWide();
        if system.is_null() {
            return None;
        }

        let mut element: AXUIElementRef = ptr::null();
        let result = AXUIElementCopyElementAtPosition(system, x as f32, y as f32, &mut element);
        CFRelease(system as CFTypeRef);
        if result != AX_ERROR_SUCCESS || element.is_null() {
            return None;
        }

        let role = accessibility_string_attribute(element, "AXRole");
        let subrole = accessibility_string_attribute(element, "AXSubrole");
        CFRelease(element as CFTypeRef);
        Some((role, subrole))
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

fn is_window_chrome_role(role: Option<&str>, subrole: Option<&str>) -> bool {
    matches!(
        role,
        Some("AXTitleBar" | "AXToolbar" | "AXMenuBar" | "AXMenuItem" | "AXButton" | "AXWindow")
    ) || matches!(
        subrole,
        Some(
            "AXCloseButton"
                | "AXMinimizeButton"
                | "AXZoomButton"
                | "AXFullScreenButton"
                | "AXToolbarButton"
        )
    )
}

fn is_translate_shortcut(event: &CGEvent) -> bool {
    let key_code = event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYCODE) as u16;
    let flags = event.get_flags();
    key_code == KeyCode::ANSI_T
        && flags.contains(CGEventFlags::CGEventFlagCommand)
        && flags.contains(CGEventFlags::CGEventFlagShift)
}

fn read_selected_text_from_clipboard_probe() -> Result<Option<String>, String> {
    let original_clipboard = command_output("pbpaste", &[]).unwrap_or_default();

    for attempt in 0..SELECTION_COPY_ATTEMPTS {
        let marker = clipboard_marker();
        write_clipboard(&marker)?;
        thread::sleep(Duration::from_millis(15));
        send_copy_shortcut()?;
        thread::sleep(Duration::from_millis(55 + (attempt as u64 * 65)));

        let selected_text = command_output("pbpaste", &[])?;
        if selected_text == marker {
            continue;
        }

        let trimmed = selected_text.trim().to_string();
        if !trimmed.is_empty() {
            let _ = write_clipboard(&original_clipboard);
            return Ok(Some(trimmed));
        }
    }

    let _ = write_clipboard(&original_clipboard);
    Ok(None)
}

fn send_copy_shortcut() -> Result<(), String> {
    let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState)
        .map_err(|_| "Could not create macOS keyboard event source.".to_string())?;
    let key_down = CGEvent::new_keyboard_event(source.clone(), KeyCode::ANSI_C, true)
        .map_err(|_| "Could not create Cmd+C key down event.".to_string())?;
    let key_up = CGEvent::new_keyboard_event(source, KeyCode::ANSI_C, false)
        .map_err(|_| "Could not create Cmd+C key up event.".to_string())?;

    key_down.set_flags(CGEventFlags::CGEventFlagCommand);
    key_up.set_flags(CGEventFlags::CGEventFlagCommand);
    key_down.post(CGEventTapLocation::HID);
    thread::sleep(Duration::from_millis(15));
    key_up.post(CGEventTapLocation::HID);
    Ok(())
}

fn write_clipboard(text: &str) -> Result<(), String> {
    let mut child = Command::new("pbcopy")
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|error| format!("Failed to run pbcopy: {error}"))?;

    if let Some(stdin) = child.stdin.as_mut() {
        stdin
            .write_all(text.as_bytes())
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

fn clipboard_marker() -> String {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    format!(
        "__ENGLIST_CLIPBOARD_MARKER_{}_{}__",
        std::process::id(),
        timestamp
    )
}

fn appkit_position_from_event(event: &CGEvent) -> CursorPosition {
    let location = event.location();
    CursorPosition {
        x: location.x.round() as i32,
        y: location.y.round() as i32,
    }
}

fn show_toolbar(toolbar_port: u16, text: String, position: CursorPosition, pending: bool) {
    let payload = ToolbarShowPayload {
        text,
        x: position.x,
        y: position.y,
        pending,
        actions: current_toolbar_actions(),
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

fn post_to_helper(port: u16, path: &str, body: &str) -> std::io::Result<()> {
    let mut stream = TcpStream::connect((IPC_HOST, port))?;
    write!(
        stream,
        "POST {path} HTTP/1.1\r\nHost: {IPC_HOST}:{port}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}

fn copy_to_clipboard(text: String) -> Result<(), String> {
    let escaped = format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""));
    let output = std::process::Command::new("osascript")
        .arg("-e")
        .arg(format!("set the clipboard to {escaped}"))
        .output()
        .map_err(|e| format!("clipboard write failed: {e}"))?;

    if !output.status.success() {
        return Err("clipboard write failed".into());
    }
    Ok(())
}

fn open_search(text: String) -> Result<(), String> {
    let query = urlencoding::encode(&text);
    let url = format!("https://www.google.com/search?q={query}");
    std::process::Command::new("open")
        .arg(&url)
        .spawn()
        .map_err(|e| format!("failed to open URL: {e}"))?;
    Ok(())
}

fn dispatch_toolbar_action(
    app: &tauri::AppHandle,
    action: ToolbarActionRequest,
) -> Result<(), String> {
    let text = action.text.trim().to_string();
    if text.is_empty() {
        return Err("empty text".into());
    }

    match action.action.as_str() {
        "copy" => copy_to_clipboard(text),
        "search" => open_search(text),
        "read" | "speak" => speak_text(text),
        "translate" | "translation" => open_popup_with_feature(app, text, "translation"),
        feature_id => open_popup_with_feature(app, text, feature_id),
    }
}

fn open_popup_with_feature(
    app: &tauri::AppHandle,
    text: String,
    feature_id: &str,
) -> Result<(), String> {
    show_popup(app)?;
    app.emit(
        "englist://ai-request",
        AiRequestPayload {
            text,
            mode: "popup_card",
            feature_id: feature_id.to_string(),
        },
    )
    .map_err(|error| format!("Could not emit AI request: {error}"))
}

fn show_popup(app: &tauri::AppHandle) -> Result<(), String> {
    let Some(window) = app.get_webview_window("popup_card") else {
        return Err("popup window was not found".into());
    };

    let already_visible = window.is_visible().unwrap_or(false);

    if already_visible {
        window
            .set_focus()
            .map_err(|error| format!("Could not focus popup: {error}"))?;
        return Ok(());
    }

    let cursor = cursor_position();
    window
        .set_size(LogicalSize::new(DEFAULT_POPUP_SIZE, DEFAULT_POPUP_SIZE))
        .map_err(|error| format!("Could not reset popup size: {error}"))?;
    window
        .set_position(LogicalPosition::new(cursor.x + 16, cursor.y + 18))
        .map_err(|error| format!("Could not position popup: {error}"))?;
    window
        .show()
        .map_err(|error| format!("Could not show popup: {error}"))?;
    window
        .set_focus()
        .map_err(|error| format!("Could not focus popup: {error}"))?;
    app.emit(
        "englist://popup-shown",
        PopupShownPayload { mode: "popup_card" },
    )
    .map_err(|error| format!("Could not emit popup shown: {error}"))
}

fn speak_text(text: String) -> Result<(), String> {
    Command::new("say")
        .arg(text)
        .spawn()
        .map_err(|error| format!("Could not start speech: {error}"))?;
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

fn command_output(program: &str, args: &[&str]) -> Result<String, String> {
    let output = Command::new(program)
        .args(args)
        .output()
        .map_err(|error| format!("Failed to run {program}: {error}"))?;

    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }

    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

fn launch_helper(app: &tauri::App, action_port: u16, toolbar_port: u16) -> anyhow::Result<()> {
    let helper_app = helper_app_path(app)?;
    if !helper_app.exists() {
        eprintln!(
            "Native selection toolbar helper app was not found: {}",
            helper_app.display()
        );
        return Ok(());
    }

    Command::new("open")
        .arg("-n")
        .arg("-g")
        .arg(helper_app)
        .arg("--args")
        .arg("--action-port")
        .arg(action_port.to_string())
        .arg("--toolbar-port")
        .arg(toolbar_port.to_string())
        .spawn()?;
    Ok(())
}

fn helper_app_path(app: &tauri::App) -> anyhow::Result<PathBuf> {
    if let Ok(resource_dir) = app.path().resource_dir() {
        let bundled = resource_dir.join("native/EnglistSelectionHelper.app");
        if bundled.exists() {
            return Ok(bundled);
        }
    }

    Ok(env::current_dir()?.join("native/EnglistSelectionHelper.app"))
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
    fn AXUIElementCopyElementAtPosition(
        application: AXUIElementRef,
        x: f32,
        y: f32,
        element: *mut AXUIElementRef,
    ) -> i32;
    fn AXUIElementCopyAttributeValue(
        element: AXUIElementRef,
        attribute: CFStringRef,
        value: *mut CFTypeRef,
    ) -> i32;
}
