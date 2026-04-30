use core_foundation::base::{CFRelease, CFTypeRef, TCFType};
use core_foundation::boolean::CFBoolean;
use core_foundation::dictionary::{CFDictionary, CFDictionaryRef};
use core_foundation::string::{CFString, CFStringRef};
use core_graphics::event::{CGEvent, CGEventFlags, CGEventTapLocation, KeyCode};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use serde::Serialize;
use std::ffi::c_void;
use std::io::Write;
use std::ptr;
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;
use std::time::{SystemTime, UNIX_EPOCH};

type AXError = i32;
type AXUIElementRef = *const c_void;

const AX_ERROR_SUCCESS: AXError = 0;

#[derive(Debug, Serialize)]
pub struct CursorPosition {
    x: i32,
    y: i32,
}

#[tauri::command]
pub fn get_selected_text() -> Result<String, String> {
    if let Some(selected_text) = read_accessibility_selected_text()? {
        return Ok(selected_text);
    }

    let original_clipboard = command_output("pbpaste", &[]).unwrap_or_default();
    let marker = clipboard_marker();

    write_clipboard(&marker)?;
    thread::sleep(Duration::from_millis(120));
    send_copy_shortcut()?;
    thread::sleep(Duration::from_millis(220));

    let selected_text = command_output("pbpaste", &[])?;
    let _ = write_clipboard(&original_clipboard);

    let trimmed = selected_text.trim().to_string();
    if selected_text == marker {
        return Err(
            "No selected text was captured. Englist Tool has Accessibility access, but the focused app did not expose AXSelectedText and did not respond to Cmd+C. Try selecting text in a standard text field first."
                .into(),
        );
    }

    if trimmed.is_empty() {
        return Err("No selected text was captured. Select text in another app and try again.".into());
    }

    Ok(trimmed)
}

fn read_accessibility_selected_text() -> Result<Option<String>, String> {
    if !is_process_trusted_for_accessibility() {
        request_accessibility_permission();
        return Err("Accessibility permission is not enabled for Englist Tool. macOS authorization has been requested; enable Englist Tool in System Settings > Privacy & Security > Accessibility, then restart the app.".into());
    }

    let system = unsafe { AXUIElementCreateSystemWide() };
    if system.is_null() {
        return Ok(None);
    }

    let focused_element = match copy_accessibility_attribute(system, "AXFocusedUIElement") {
        Ok(Some(element)) => element,
        Ok(None) => {
            unsafe { CFRelease(system as CFTypeRef) };
            return Ok(None);
        }
        Err(error) => {
            unsafe { CFRelease(system as CFTypeRef) };
            return Err(error);
        }
    };
    unsafe { CFRelease(system as CFTypeRef) };

    let selected_value = copy_accessibility_attribute(focused_element as AXUIElementRef, "AXSelectedText");
    unsafe { CFRelease(focused_element) };

    let Some(selected_value) = selected_value? else {
        return Ok(None);
    };

    let selected_text =
        unsafe { CFString::wrap_under_create_rule(selected_value as CFStringRef).to_string() };
    let trimmed = selected_text.trim().to_string();
    if trimmed.is_empty() {
        return Ok(None);
    }

    Ok(Some(trimmed))
}

fn copy_accessibility_attribute(
    element: AXUIElementRef,
    attribute_name: &str,
) -> Result<Option<CFTypeRef>, String> {
    let attribute = CFString::new(attribute_name);
    let mut value: CFTypeRef = ptr::null();
    let status = unsafe {
        AXUIElementCopyAttributeValue(element, attribute.as_concrete_TypeRef(), &mut value)
    };

    if status == AX_ERROR_SUCCESS && !value.is_null() {
        return Ok(Some(value));
    }

    Ok(None)
}

fn is_process_trusted_for_accessibility() -> bool {
    unsafe { AXIsProcessTrusted() }
}

fn request_accessibility_permission() -> bool {
    let prompt_key = unsafe { CFString::wrap_under_get_rule(kAXTrustedCheckOptionPrompt) };
    let prompt_value = CFBoolean::true_value();
    let options = CFDictionary::from_CFType_pairs(&[(prompt_key, prompt_value)]);
    unsafe { AXIsProcessTrustedWithOptions(options.as_concrete_TypeRef()) }
}

#[tauri::command]
pub fn cursor_position() -> CursorPosition {
    let script = [
        "use framework \"AppKit\"",
        "set mouseLoc to current application's NSEvent's mouseLocation()",
        "return ((mouseLoc's x) as integer) & \",\" & ((mouseLoc's y) as integer)",
    ];

    let args = ["-e", script[0], "-e", script[1], "-e", script[2]];
    let output = command_output("osascript", &args).unwrap_or_else(|_| "420,260".into());
    let mut parts = output.trim().split(',');

    CursorPosition {
        x: parts.next().and_then(|value| value.parse().ok()).unwrap_or(420),
        y: parts.next().and_then(|value| value.parse().ok()).unwrap_or(260),
    }
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

fn send_copy_shortcut() -> Result<(), String> {
    let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState)
        .map_err(|_| "Could not create macOS keyboard event source.".to_string())?;
    let key_down = CGEvent::new_keyboard_event(source.clone(), KeyCode::ANSI_C, true)
        .map_err(|_| "Could not create Cmd+C key down event.".to_string())?;
    let key_up = CGEvent::new_keyboard_event(source, KeyCode::ANSI_C, false)
        .map_err(|_| "Could not create Cmd+C key up event.".to_string())?;

    key_down.set_flags(CGEventFlags::CGEventFlagCommand);
    key_up.set_flags(CGEventFlags::CGEventFlagCommand);
    key_down.post(CGEventTapLocation::Session);
    thread::sleep(Duration::from_millis(30));
    key_up.post(CGEventTapLocation::Session);
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
    format!("__ENGLIST_CLIPBOARD_MARKER_{}_{}__", std::process::id(), timestamp)
}

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrusted() -> bool;
    static kAXTrustedCheckOptionPrompt: CFStringRef;
    fn AXIsProcessTrustedWithOptions(options: CFDictionaryRef) -> bool;
    fn AXUIElementCreateSystemWide() -> AXUIElementRef;
    fn AXUIElementCopyAttributeValue(
        element: AXUIElementRef,
        attribute: CFStringRef,
        value: *mut CFTypeRef,
    ) -> AXError;
}
