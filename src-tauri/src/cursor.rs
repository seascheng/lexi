use core_graphics::display::CGDisplay;
use serde::Serialize;
use std::process::Command;

#[derive(Clone, Copy, Debug, Serialize)]
pub struct CursorPosition {
    pub x: i32,
    pub y: i32,
}

/// Returns cursor position in the coordinate system Tauri/tao expects
/// (origin at top-left of main screen, y increasing downward).
///
/// This mirrors tao's own cursor_position() and window_position() logic:
///   flipped_y = CGDisplay::main().pixels_high() - NSEvent.mouseLocation().y
#[tauri::command]
pub fn cursor_position() -> CursorPosition {
    // Get mouse location from NSEvent (Cocoa coordinates, bottom-left origin)
    let script = [
        "use framework \"AppKit\"",
        "set mouseLoc to current application's NSEvent's mouseLocation()",
        "return ((mouseLoc's x) as text) & \",\" & ((mouseLoc's y) as text)",
    ];
    let args: Vec<&str> = script.iter().flat_map(|s| ["-e", *s]).collect();
    let output = run("osascript", &args).unwrap_or_else(|_| "420,260".into());
    let mut parts = output.trim().split(',');

    let cocoa_x: f64 = parts.next().and_then(|v| v.parse().ok()).unwrap_or(420.0);
    let cocoa_y: f64 = parts.next().and_then(|v| v.parse().ok()).unwrap_or(260.0);

    // Flip y using the same API tao uses (CGDisplay::main().pixels_high())
    let main_height = CGDisplay::main().pixels_high() as f64;
    let flipped_y = main_height - cocoa_y;

    CursorPosition {
        x: cocoa_x.round() as i32,
        y: flipped_y.round() as i32,
    }
}

fn run(program: &str, args: &[&str]) -> Result<String, String> {
    let output = Command::new(program)
        .args(args)
        .output()
        .map_err(|e| format!("Failed to run {program}: {e}"))?;
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}
