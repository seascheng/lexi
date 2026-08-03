use core_graphics::display::CGDisplay;
use core_graphics::event::CGEvent;
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use serde::Serialize;

#[derive(Clone, Copy, Debug, Serialize)]
pub struct CursorPosition {
    pub x: i32,
    pub y: i32,
}

/// Height (in points) of the primary display — the display holding the menu bar.
/// Both global coordinate spaces on macOS are anchored at a corner of the
/// primary display, so this single value converts between them for any point,
/// on any screen: `cocoa_y + cg_y == primary_height_points()`.
fn primary_height_points() -> f64 {
    CGDisplay::main().bounds().size.height as f64
}

/// Read the live hardware cursor position from the HID system state, returned
/// in **Core Graphics / Quartz global coordinates** (origin at the top-left of
/// the primary display, y increasing downward) — the same space
/// `CGEvent.location()`, `CGDisplay::bounds()`, and Tauri/tao window positioning
/// (`LogicalPosition`) use.
///
/// This is the authoritative cursor position regardless of which app is
/// frontmost or which display the cursor is on, unlike `NSEvent.mouseLocation`,
/// which only reflects mouse events the caller's own event loop has processed
/// and therefore goes stale when the interaction happens in another app.
fn cg_mouse_location() -> Option<(f64, f64)> {
    let source = CGEventSource::new(CGEventSourceStateID::HIDSystemState).ok()?;
    let event = CGEvent::new(source).ok()?;
    let loc = event.location();
    Some((loc.x, loc.y))
}

/// Live cursor location in **Cocoa / AppKit global coordinates** (origin at the
/// bottom-left of the primary display, y increasing upward) — the space
/// `NSScreen.frame` and `NSPanel.setFrame` use. This is what the native toolbar
/// helper expects, so it can run `NSScreen.contains(...)` and place its panel.
pub fn mouse_location() -> CursorPosition {
    if let Some((x, cg_y)) = cg_mouse_location() {
        return CursorPosition {
            x: x.round() as i32,
            // Flip CG (top-left, y down) → Cocoa (bottom-left, y up).
            y: (primary_height_points() - cg_y).round() as i32,
        };
    }
    // Unreachable in practice once the app holds Input Monitoring (the same API
    // is already used for popup resize); keep a sane on-screen default.
    CursorPosition { x: 420, y: 260 }
}

/// Cursor location in the coordinate system Tauri/tao expects for window
/// positioning: origin at the top-left of the primary display, y increasing
/// downward — i.e. Core Graphics global coordinates. `CGEvent.location()` is
/// already in this space, so no flip is needed.
///
/// The previous implementation shelled out to `osascript` for
/// `NSEvent.mouseLocation` (Cocoa space) and flipped with `pixels_high()`
/// (backing pixels), which both spawned a subprocess per call and doubled the
/// offset on retina displays. Reading the HID state directly is faster and
/// correct on any DPI / multi-monitor layout.
#[tauri::command]
pub fn cursor_position() -> CursorPosition {
    if let Some((x, y)) = cg_mouse_location() {
        return CursorPosition {
            x: x.round() as i32,
            y: y.round() as i32,
        };
    }
    CursorPosition { x: 420, y: 260 }
}
