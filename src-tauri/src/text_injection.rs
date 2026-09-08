// Text delivery engine — writes text back into the app the user selected from.
//
// Ported from tinycast's TextInjector contract (three tiers, fall through only
// on failure):
//   1. AX direct write (AXSelectedText) + readback verification
//   2. Unicode keyboard events (≤4 UTF-16 units per keystroke)
//   3. Temporary pasteboard lease + synthesized Cmd+V
//
// Safety gates re-checked before every tier and every posted event: the target
// app is still frontmost and Secure Event Input is off.

use crate::ax::{
    accessibility_string_attribute, ax_attribute_settable, ax_selected_range,
    ax_set_selected_range, ax_set_string_attribute, element_has_marker_selection,
    focused_element_of, frontmost_pid, secure_input_enabled, AXUIElementCreateApplication,
    AXUIElementRef,
};
use crate::native_toolbar::{
    flags_changed_event, key_event, log_native, pasteboard_change_count,
    pasteboard_safe_to_borrow, read_pasteboard_string_via_pb, restore_pasteboard,
    selection_read_guard, write_clipboard, CMD_KEYCODE,
};
use core_foundation::base::{CFRelease, TCFType};

use core_graphics::event::{CGEvent, CGEventFlags, KeyCode};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use std::thread;
use std::time::Duration;

/// Insert text at the caret of the app the popup was summoned from — the
/// Hapigo-style "pick a note, press Enter, it lands in the input" flow.
#[tauri::command]
pub fn insert_at_focus(text: String) -> Result<String, String> {
    deliver_text(&text).map(|tier| tier.to_string())
}

/// Text short enough for the keystroke tier: single line only — synthesized
/// Return keypresses for "\n" would trigger buttons/submits in the target.
const UNICODE_TIER_MAX_CHARS: usize = 100;
/// Blink caps one key event's text at 4 UTF-16 units (`WebKeyboardEvent::
/// kTextLengthCap`) and silently drops the rest — chunk on scalar boundaries.
const UNICODE_CHUNK_UTF16_UNITS: usize = 4;
const KEYSTROKE_INTERVAL_MS: u64 = 8;
/// How long the pasteboard lease holds the text before the synthesized ⌘V,
/// and how long we wait for the target's text state to change afterwards.
const PASTE_SETTLE_MS: u64 = 80;
const PASTE_CONFIRM_ATTEMPTS: usize = 40;
const PASTE_CONFIRM_INTERVAL_MS: u64 = 25;

/// Deliver `text` into the app captured by the last selection/popup gesture:
/// replaces the current selection, or inserts at the caret when none.
/// Returns which tier delivered ("ax" | "typed" | "pasted").
pub(crate) fn deliver_text(text: &str) -> Result<&'static str, String> {
    if text.trim().is_empty() {
        return Err("Nothing to insert.".into());
    }
    if secure_input_enabled() {
        return Err("Secure input is active (password field?); insertion skipped.".into());
    }

    let target = crate::native_toolbar::current_selection_target()
        .ok_or("No recent selection target to write back to.")?;
    let pid = target.pid;

    // AX client caches are not thread-safe; serialize with selection workers.
    let _guard = selection_read_guard();

    if !wait_for_frontmost(pid) {
        return Err(format!(
            "Target app (pid {pid}, {}) could not be brought to the front.",
            target.bundle_id
        ));
    }

    match ax_write_tier(text, pid) {
        AxTier::Delivered => {
            log_native(&format!("inject: ax tier delivered len={}", text.len()));
            return Ok("ax");
        }
        AxTier::Rejected(reason) => return Err(reason),
        AxTier::Unavailable => {}
    }

    let single_line = !text.contains('\n') && !text.contains('\r');
    if text.chars().count() <= UNICODE_TIER_MAX_CHARS && single_line {
        if unicode_tier(text, pid) {
            log_native(&format!("inject: unicode tier delivered len={}", text.len()));
            return Ok("typed");
        }
        return Err("Keystroke delivery did not complete.".into());
    }

    paste_tier(text, pid)
}

enum AxTier {
    Delivered,
    Rejected(String),
    Unavailable,
}

/// Tier 1 — write over Accessibility and verify by readback. Chromium answers
/// `.success` and applies nothing, so an unverified write is not evidence.
fn ax_write_tier(text: &str, pid: i32) -> AxTier {
    unsafe {
        let app = AXUIElementCreateApplication(pid);
        if app.is_null() {
            return AxTier::Unavailable;
        }
        let outcome = ax_write_inner(app, text);
        CFRelease(app);
        outcome
    }
}

unsafe fn ax_write_inner(app: AXUIElementRef, text: &str) -> AxTier {
    let Some(focused) = focused_element_of(app) else {
        return AxTier::Unavailable;
    };
    let outcome = (|| -> AxTier {
        // Renderer surfaces (Chromium/Monaco) publish selection as opaque text
        // markers and their AXValue trails the real editor — never write there.
        if element_has_marker_selection(focused) {
            return AxTier::Unavailable;
        }
        if !(ax_attribute_settable(focused, "AXSelectedText")
            && ax_attribute_settable(focused, "AXSelectedTextRange"))
        {
            return AxTier::Unavailable;
        }
        let Some(value) = accessibility_string_attribute(focused, "AXValue") else {
            return AxTier::Unavailable;
        };
        let Some((loc, len)) = ax_selected_range(focused) else {
            return AxTier::Unavailable;
        };
        // AX ranges are UTF-16 offsets; a range the value can't address is a
        // broken tier, not proof the document moved.
        let value16: Vec<u16> = value.encode_utf16().collect();
        if loc + len > value16.len() {
            return AxTier::Unavailable;
        }
        // Re-assert the range so the write targets the selection deterministically.
        if !ax_set_selected_range(focused, loc, len) {
            return AxTier::Unavailable;
        }
        if !ax_set_string_attribute(focused, "AXSelectedText", text) {
            let _ = ax_set_selected_range(focused, loc, len);
            return AxTier::Unavailable;
        }

        let observed = accessibility_string_attribute(focused, "AXValue");
        let mut expected: Vec<u16> = value16[..loc].to_vec();
        expected.extend(text.encode_utf16());
        expected.extend_from_slice(&value16[loc + len..]);
        let verified = observed
            .as_deref()
            .map(|obs| obs.encode_utf16().eq(expected.iter().copied()))
            .unwrap_or(false);
        if verified {
            let inserted = text.encode_utf16().count();
            let _ = ax_set_selected_range(focused, loc + inserted, 0);
            return AxTier::Delivered;
        }
        let _ = ax_set_selected_range(focused, loc, len);
        if observed.as_deref() == Some(value.as_str()) {
            // Tier did nothing → the event tiers still get their turn.
            return AxTier::Unavailable;
        }
        AxTier::Rejected("Target document changed unexpectedly; replacement aborted.".into())
    })();
    CFRelease(focused);
    outcome
}

/// Tier 2 — synthesize Unicode keystrokes posted to the target pid.
fn unicode_tier(text: &str, pid: i32) -> bool {
    let mut chunks: Vec<Vec<u16>> = Vec::new();
    let mut current: Vec<u16> = Vec::with_capacity(UNICODE_CHUNK_UTF16_UNITS);
    for scalar in text.chars() {
        let mut buf = [0u16; 2];
        let encoded = scalar.encode_utf16(&mut buf);
        if current.len() + encoded.len() > UNICODE_CHUNK_UTF16_UNITS {
            chunks.push(std::mem::take(&mut current));
        }
        current.extend_from_slice(encoded);
    }
    if !current.is_empty() {
        chunks.push(current);
    }

    for (index, chunk) in chunks.iter().enumerate() {
        if index > 0 {
            thread::sleep(Duration::from_millis(KEYSTROKE_INTERVAL_MS));
        }
        // Gates re-checked before every post: a target that went away or went
        // secure stops delivery immediately.
        if secure_input_enabled() || unsafe { frontmost_pid() } != Some(pid) {
            return false;
        }
        if !(unsafe { post_unicode_keystroke(chunk, pid) }) {
            return false;
        }
    }
    // Let the target apply the final keystroke before the caller reports success.
    thread::sleep(Duration::from_millis(100));
    true
}

unsafe fn post_unicode_keystroke(chunk: &[u16], pid: i32) -> bool {
    let Ok(source) = CGEventSource::new(CGEventSourceStateID::CombinedSessionState) else {
        return false;
    };
    let (Ok(down), Ok(up)) = (
        CGEvent::new_keyboard_event(source.clone(), 0, true),
        CGEvent::new_keyboard_event(source, 0, false),
    ) else {
        return false;
    };
    for event in [&down, &up] {
        event.set_string_from_utf16_unchecked(chunk);
        event.post_to_pid(pid);
    }
    true
}

/// Tier 3 — lend the pasteboard the text alone, synthesize the full ⌘V
/// modifier sequence, confirm by AX readback, restore the user's clipboard.
fn paste_tier(text: &str, pid: i32) -> Result<&'static str, String> {
    if !pasteboard_safe_to_borrow() {
        // Image/file clipboard is never borrowed — type the text instead.
        if unicode_tier(text, pid) {
            return Ok("typed");
        }
        return Err("Clipboard holds non-text content; nothing was disturbed.".into());
    }

    let pre_text = read_pasteboard_string_via_pb();
    if let Err(e) = write_clipboard(text) {
        return Err(format!("Could not write clipboard: {e}"));
    }
    let count_after_write = unsafe { pasteboard_change_count() };

    thread::sleep(Duration::from_millis(PASTE_SETTLE_MS));
    if secure_input_enabled() || unsafe { frontmost_pid() } != Some(pid) {
        restore_pasteboard(pre_text.as_deref());
        return Err("Target app lost focus; paste aborted.".into());
    }
    unsafe { post_command_v(pid) };

    let before = focused_value_snapshot(pid);
    let mut confirmed = false;
    if before.is_some() {
        for _ in 0..PASTE_CONFIRM_ATTEMPTS {
            thread::sleep(Duration::from_millis(PASTE_CONFIRM_INTERVAL_MS));
            if let Some(now) = focused_value_snapshot(pid) {
                if Some(now) != before {
                    confirmed = true;
                    break;
                }
            }
        }
    } else {
        // Renderer surfaces expose no comparable value — fixed settle instead.
        thread::sleep(Duration::from_millis(300));
        confirmed = true;
    }

    // Restore the user's clipboard unless someone else wrote meanwhile.
    if unsafe { pasteboard_change_count() } == count_after_write {
        restore_pasteboard(pre_text.as_deref());
    }
    if !confirmed {
        return Err("Paste was sent but could not be verified.".into());
    }
    log_native(&format!("inject: paste tier delivered len={}", text.len()));
    Ok("pasted")
}

/// Full ⌘V sequence (the two FlagsChanged events update the target's live
/// modifier state — without them apps that read modifiers see a bare "v").
unsafe fn post_command_v(pid: i32) {
    let cmd = CGEventFlags::CGEventFlagCommand;
    if let Some(event) = flags_changed_event(CMD_KEYCODE, cmd) {
        event.post_to_pid(pid);
    }
    if let Some(event) = key_event(KeyCode::ANSI_V, true, cmd) {
        event.post_to_pid(pid);
    }
    if let Some(event) = key_event(KeyCode::ANSI_V, false, cmd) {
        event.post_to_pid(pid);
    }
    if let Some(event) = flags_changed_event(CMD_KEYCODE, CGEventFlags::empty()) {
        event.post_to_pid(pid);
    }
}

/// Current text state of the target's focused element, for paste confirmation.
/// `None` on renderer surfaces (marker selections) and unreadable elements.
fn focused_value_snapshot(pid: i32) -> Option<String> {
    unsafe {
        let app = AXUIElementCreateApplication(pid);
        if app.is_null() {
            return None;
        }
        let snapshot = (|| {
            let focused = focused_element_of(app)?;
            if element_has_marker_selection(focused) {
                CFRelease(focused);
                return None;
            }
            let value = accessibility_string_attribute(focused, "AXValue");
            CFRelease(focused);
            value
        })();
        CFRelease(app);
        snapshot
    }
}

/// True when the target app is (or has been brought back to) the frontmost app.
pub(crate) fn wait_for_frontmost(pid: i32) -> bool {
    for attempt in 0..50 {
        if unsafe { frontmost_pid() } == Some(pid) {
            return true;
        }
        if attempt == 0 {
            unsafe { activate_pid(pid) };
        }
        thread::sleep(Duration::from_millis(20));
    }
    false
}

/// `NSRunningApplication.activateWithOptions:` for a pid.
pub(crate) unsafe fn activate_pid(pid: i32) -> bool {
    let pool = crate::ax::new_autorelease_pool();
    let activated = activate_pid_inner(pid);
    crate::ax::drain_autorelease_pool(pool);
    activated
}

unsafe fn activate_pid_inner(pid: i32) -> bool {
    let cls = crate::ax::objc_getClass(b"NSRunningApplication\0".as_ptr() as *const i8);
    if cls.is_null() {
        return false;
    }
    let sel = crate::ax::sel_registerName(
        b"runningApplicationWithProcessIdentifier:\0".as_ptr() as *const i8,
    );
    let running_app = crate::ax::objc_msgSend(
        cls as *mut std::ffi::c_void,
        sel,
        pid as i64,
    );
    if running_app.is_null() {
        return false;
    }
    let activate =
        crate::ax::sel_registerName(b"activateWithOptions:\0".as_ptr() as *const i8);
    // NSApplicationActivateIgnoringOtherApps = 1 << 1
    crate::ax::objc_msgSend(running_app, activate, 2u64);
    true
}

/// Activate the first running app whose bundle id equals `bundle`; returns its pid.
/// Used by the handoff tool ("send to ChatGPT") — no osascript, no escaping.
pub(crate) fn activate_app_by_bundle_id(bundle: &str) -> Option<i32> {
    unsafe {
        let pool = crate::ax::new_autorelease_pool();
        let pid = activate_app_by_bundle_id_inner(bundle);
        crate::ax::drain_autorelease_pool(pool);
        pid
    }
}

unsafe fn activate_app_by_bundle_id_inner(bundle: &str) -> Option<i32> {
    let cls = crate::ax::objc_getClass(b"NSWorkspace\0".as_ptr() as *const i8);
    let shared_sel = crate::ax::sel_registerName(b"sharedWorkspace\0".as_ptr() as *const i8);
    let workspace = crate::ax::objc_msgSend(cls as *mut std::ffi::c_void, shared_sel);
    if workspace.is_null() {
        return None;
    }
    let apps_sel = crate::ax::sel_registerName(b"runningApplications\0".as_ptr() as *const i8);
    let apps = crate::ax::objc_msgSend(workspace, apps_sel);
    if apps.is_null() {
        return None;
    }

    let count = crate::ax::CFArrayGetCount(apps);
    let bundle_sel = crate::ax::sel_registerName(b"bundleIdentifier\0".as_ptr() as *const i8);
    let name_sel = crate::ax::sel_registerName(b"localizedName\0".as_ptr() as *const i8);
    let pid_sel = crate::ax::sel_registerName(b"processIdentifier\0".as_ptr() as *const i8);
    let activate =
        crate::ax::sel_registerName(b"activateWithOptions:\0".as_ptr() as *const i8);

    // The handoff setting stores a user-facing app name ("ChatGPT"), not a
    // bundle id — match either, case-insensitively.
    let wanted_lower = bundle.to_lowercase();
    let mut result = None;
    for index in 0..count {
        let app = crate::ax::CFArrayGetValueAtIndex(apps, index);
        if app.is_null() {
            continue;
        }
        let matches = [bundle_sel, name_sel].iter().any(|sel| {
            let value = crate::ax::objc_msgSend(app as *mut std::ffi::c_void, *sel);
            if value.is_null() {
                return false;
            }
            // NSString and CFString are toll-free bridged — compare as CFString.
            let app_string = core_foundation::string::CFString::wrap_under_get_rule(
                value as core_foundation::string::CFStringRef,
            );
            app_string.to_string().to_lowercase() == wanted_lower
        });
        if !matches {
            continue;
        }
        let pid = crate::ax::objc_msgSend(app as *mut std::ffi::c_void, pid_sel) as i32;
        if pid <= 0 {
            continue;
        }
        // NSApplicationActivateIgnoringOtherApps = 1 << 1
        crate::ax::objc_msgSend(app as *mut std::ffi::c_void, activate, 2u64);
        result = Some(pid);
        break;
    }
    result
}

/// Paste `text` into the (already frontmost) app at pid — the handoff path.
/// Lease the pasteboard, ⌘V, confirm, restore. Exposed separately because
/// handoff activates its own target app first.
pub(crate) fn paste_text(pid: i32, text: &str) -> Result<&'static str, String> {
    if secure_input_enabled() {
        return Err("Secure input is active; handoff skipped.".into());
    }
    let _guard = selection_read_guard();
    paste_tier(text, pid)
}

