use base64::Engine;
use futures_util::StreamExt;
use serde::Deserialize;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use tauri::Manager;

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct TtsConfig {
    engine: Option<String>,
    volc_app_id: Option<String>,
    volc_access_token: Option<String>,
    volc_voice: Option<String>,
}

/// Read the "read" tool config from the SQLite settings DB.
fn read_tool_config(db_path: &Path) -> TtsConfig {
    let output = match Command::new("sqlite3")
        .arg(db_path)
        .arg("SELECT value FROM settings WHERE key = 'toolbar_tools' LIMIT 1;")
        .output()
    {
        Ok(o) if o.status.success() => o,
        _ => return TtsConfig::default(),
    };

    let raw = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if raw.is_empty() {
        return TtsConfig::default();
    }

    let tools: Vec<serde_json::Value> = match serde_json::from_str(&raw) {
        Ok(v) => v,
        Err(_) => return TtsConfig::default(),
    };

    tools
        .iter()
        .find(|t| t["id"].as_str() == Some("read"))
        .and_then(|t| t.get("config").cloned())
        .and_then(|c| serde_json::from_value(c).ok())
        .unwrap_or_default()
}

/// Core speech dispatcher: reads config from DB, routes to the correct engine.
async fn dispatch(text: &str, db_path: &Path) -> Result<(), String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Err("Nothing to speak.".into());
    }

    let config = read_tool_config(db_path);
    let engine = config.engine.as_deref().unwrap_or("system");

    eprintln!(
        "[speech] engine={engine}, app_id={:?}, has_token={}, voice={:?}",
        config.volc_app_id,
        config.volc_access_token.is_some(),
        config.volc_voice
    );

    match engine {
        "volcengine" => speak_volcengine(trimmed, &config).await,
        _ => speak_system(trimmed),
    }
}

/// Public entry point for direct backend invocation (toolbar dispatch).
pub async fn speak_with_db_path(text: String, db_path: PathBuf) -> Result<(), String> {
    dispatch(&text, &db_path).await
}

#[tauri::command]
pub async fn speak_text(app: tauri::AppHandle, text: String) -> Result<(), String> {
    let db_path = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("Could not resolve app data dir: {e}"))?
        .join("lexi.db");

    dispatch(&text, &db_path).await
}

async fn speak_volcengine(text: &str, config: &TtsConfig) -> Result<(), String> {
    let app_id = config
        .volc_app_id
        .as_deref()
        .ok_or("Volcengine APP ID not configured")?;
    let access_token = config
        .volc_access_token
        .as_deref()
        .ok_or("Volcengine Access Token not configured")?;
    let voice = config
        .volc_voice
        .as_deref()
        .unwrap_or("zh_female_cancan_mars_bigtts");

    eprintln!(
        "[speech] HTTP request: voice={voice}, text={}",
        &text[..text.len().min(50)]
    );

    let client = reqwest::Client::new();
    let body = serde_json::json!({
        "user": { "uid": "lexi_user" },
        "req_params": {
            "text": text,
            "speaker": voice,
            "audio_params": {
                "format": "mp3",
                "sample_rate": 24000,
            }
        }
    });

    let resp = client
        .post("https://openspeech.bytedance.com/api/v3/tts/unidirectional")
        .header("X-Api-App-Id", app_id)
        .header("X-Api-Access-Key", access_token)
        .header("X-Api-Resource-Id", "seed-tts-1.0")
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("TTS request failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        return Err(format!("TTS HTTP error {status}: {text}"));
    }

    let mut audio = Vec::new();
    let b64 = base64::engine::general_purpose::STANDARD;
    let mut buffer = Vec::new();

    let mut stream = resp.bytes_stream();
    while let Some(chunk_result) = stream.next().await {
        let chunk = chunk_result.map_err(|e| format!("TTS stream read error: {e}"))?;
        buffer.extend_from_slice(&chunk);

        while let Some(pos) = buffer.iter().position(|&b| b == b'\n') {
            let line_bytes: Vec<u8> = buffer.drain(..=pos).collect();
            let line = String::from_utf8_lossy(&line_bytes).trim().to_string();
            if line.is_empty() {
                continue;
            }

            let parsed: serde_json::Value = match serde_json::from_str(&line) {
                Ok(v) => v,
                Err(_) => continue,
            };

            let code = parsed["code"].as_u64().unwrap_or(0);
            if code == 20000000 {
                buffer.clear();
                break;
            }
            if code != 0 {
                let msg = parsed["message"].as_str().unwrap_or("unknown");
                return Err(format!("TTS error code {code}: {msg}"));
            }

            if let Some(data) = parsed["data"].as_str() {
                if !data.is_empty() {
                    audio.extend_from_slice(
                        &b64.decode(data)
                            .map_err(|e| format!("TTS base64 decode error: {e}"))?,
                    );
                }
            }
        }
    }

    // Fallback: try parsing remaining buffer as one JSON object
    if audio.is_empty() && !buffer.is_empty() {
        let remaining = String::from_utf8_lossy(&buffer).trim().to_string();
        if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&remaining) {
            if let Some(data) = parsed["data"].as_str() {
                if !data.is_empty() {
                    audio.extend_from_slice(&b64.decode(data).unwrap_or_default());
                }
            }
        }
    }

    eprintln!("[speech] total audio: {} bytes", audio.len());

    if audio.is_empty() {
        return Err("No audio received from Volcengine TTS.".into());
    }

    let temp_dir = std::env::temp_dir();
    let id = format!(
        "{:x}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    );
    let temp_path = temp_dir.join(format!("lexi_tts_{}.mp3", &id[..16]));

    let mut file =
        std::fs::File::create(&temp_path).map_err(|e| format!("Temp file error: {e}"))?;
    file.write_all(&audio)
        .map_err(|e| format!("Write audio error: {e}"))?;

    eprintln!("[speech] playing {}", temp_path.display());

    #[cfg(target_os = "macos")]
    {
        let path = temp_path.clone();
        std::thread::spawn(move || {
            let _ = Command::new("afplay").arg(&path).status();
            let _ = std::fs::remove_file(&path);
        });
    }

    Ok(())
}

fn speak_system(text: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        Command::new("say")
            .arg(text)
            .spawn()
            .map_err(|e| format!("Could not start macOS speech: {e}"))?;
        Ok(())
    }

    #[cfg(not(target_os = "macos"))]
    {
        let _ = text;
        Err("System speech is only available on macOS.".into())
    }
}
