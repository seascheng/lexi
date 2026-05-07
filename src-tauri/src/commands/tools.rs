use std::path::PathBuf;
use std::process::Command;
use tauri::{Emitter, Manager};

/// Unified tool executor — single entry point for all tool actions.
/// Both toolbar dispatch and frontend invoke call this.
#[tauri::command]
pub async fn execute_tool(
    app: tauri::AppHandle,
    id: String,
    text: String,
) -> Result<(), String> {
    let trimmed = text.trim().to_string();
    if trimmed.is_empty() {
        return Err("Empty text.".into());
    }

    match id.as_str() {
        "copy" => tool_copy(trimmed),
        "search" => tool_search(&app, &trimmed),
        "read" => tool_read(&app, trimmed).await,
        "note" => tool_note(&app, trimmed),
        "handoff" => tool_handoff(&app, trimmed),
        _ => Err(format!("Unknown tool: {id}")),
    }
}

// --- Tool implementations ---

fn tool_copy(text: String) -> Result<(), String> {
    write_clipboard(&text)
}

fn tool_search(app: &tauri::AppHandle, text: &str) -> Result<(), String> {
    let config = read_tool_config(app, "search");
    let engine = config["engine"].as_str().unwrap_or("google");
    let encoded = urlencoding::encode(text);

    let url = match engine {
        "bing" => format!("https://www.bing.com/search?q={encoded}"),
        "duckduckgo" => format!("https://duckduckgo.com/?q={encoded}"),
        "custom" => {
            let template = config["customUrl"].as_str().unwrap_or("");
            template.replace("{query}", &encoded.to_string())
        }
        _ => format!("https://www.google.com/search?q={encoded}"),
    };

    if url.is_empty() {
        return Err("No search URL configured.".into());
    }

    Command::new("open")
        .arg(&url)
        .spawn()
        .map_err(|e| format!("Failed to open URL: {e}"))?;
    Ok(())
}

async fn tool_read(app: &tauri::AppHandle, text: String) -> Result<(), String> {
    let db_path = db_path(app)?;
    crate::commands::speech::speak_with_db_path(text, db_path).await
}

fn tool_note(app: &tauri::AppHandle, text: String) -> Result<(), String> {
    let path = db_path(app)?;
    let now = chrono_now();
    // Insert note with default tag "Tmp"
    let output = Command::new("sqlite3")
        .arg(&path)
        .arg(format!(
            "INSERT INTO notes (name, content, created_at) VALUES (NULL, '{}', '{}'); \
             SELECT id FROM notes ORDER BY id DESC LIMIT 1;",
            sqlite_escape(&text),
            now,
        ))
        .output()
        .map_err(|e| format!("Note save failed: {e}"))?;

    if !output.status.success() {
        return Err(format!("Note save error: {}", String::from_utf8_lossy(&output.stderr)));
    }

    let note_id = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if let Ok(id) = note_id.parse::<i64>() {
        // Get or create "Tmp" tag and link note
        let _ = Command::new("sqlite3")
            .arg(&path)
            .arg(format!(
                "INSERT OR IGNORE INTO tags (name) VALUES ('Tmp'); \
                 INSERT INTO note_tags (note_id, tag_id) \
                 SELECT {id}, id FROM tags WHERE name = 'Tmp';"
            ))
            .output();
    }

    // Notify frontend to refresh notes list
    let _ = app.emit("lexi://notes-changed", ());

    eprintln!("[tool:note] saved note id={note_id}");
    Ok(())
}

fn tool_handoff(app: &tauri::AppHandle, text: String) -> Result<(), String> {
    // Read target app from tool config in DB, fallback to global state
    let config = read_tool_config(app, "handoff");
    let target_app = config["targetApp"]
        .as_str()
        .unwrap_or("ChatGPT")
        .to_string();

    if target_app.is_empty() {
        return Err("No handoff target app configured.".into());
    }

    write_clipboard(&text)?;

    let script = format!(
        r#"tell application "{}" to activate
delay 1.0
tell application "System Events"
    keystroke "v" using command down
end tell"#,
        target_app.replace('\\', "\\\\").replace('"', "\\\""),
    );

    let output = Command::new("osascript")
        .arg("-e")
        .arg(&script)
        .output()
        .map_err(|error| format!("Handoff failed: {error}"))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("Handoff error: {stderr}"));
    }
    Ok(())
}

// --- Helpers ---

fn write_clipboard(text: &str) -> Result<(), String> {
    use std::io::Write;
    let mut child = Command::new("pbcopy")
        .env("LANG", "en_US.UTF-8")
        .stdin(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("pbcopy failed: {e}"))?;
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(text.as_bytes());
    }
    let _ = child.wait();
    Ok(())
}

fn db_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    app.path()
        .app_data_dir()
        .map(|dir| dir.join("lexi.db"))
        .map_err(|e| format!("Could not resolve app data dir: {e}"))
}

/// Read a tool's config from the DB.
fn read_tool_config(app: &tauri::AppHandle, tool_id: &str) -> serde_json::Value {
    let path = match db_path(app) {
        Ok(p) => p,
        Err(_) => return serde_json::json!({}),
    };

    let output = match Command::new("sqlite3")
        .arg(&path)
        .arg("SELECT value FROM settings WHERE key = 'toolbar_tools' LIMIT 1;")
        .output()
    {
        Ok(o) if o.status.success() => o,
        _ => return serde_json::json!({}),
    };

    let raw = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let tools: Vec<serde_json::Value> = serde_json::from_str(&raw).unwrap_or_default();

    tools
        .iter()
        .find(|t| t["id"].as_str() == Some(tool_id))
        .and_then(|t| t.get("config").cloned())
        .unwrap_or(serde_json::json!({}))
}

fn sqlite_escape(s: &str) -> String {
    s.replace('\'', "''")
}

fn chrono_now() -> String {
    let output = Command::new("date")
        .arg("+%Y-%m-%dT%H:%M:%SZ")
        .output();
    match output {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => "2026-01-01T00:00:00Z".to_string(),
    }
}
