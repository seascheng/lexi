use serde::Serialize;
use std::process::Command;

#[derive(Clone, Copy, Debug, Serialize)]
pub struct CursorPosition {
    pub x: i32,
    pub y: i32,
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
        x: parts
            .next()
            .and_then(|value| value.parse().ok())
            .unwrap_or(420),
        y: parts
            .next()
            .and_then(|value| value.parse().ok())
            .unwrap_or(260),
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
