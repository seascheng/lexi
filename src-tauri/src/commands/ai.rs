use reqwest::header::{AUTHORIZATION, CONTENT_TYPE};
use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant};
use tauri::Emitter;

use super::http::http_client;

fn log_ai(message: &str) {
    use std::io::Write;
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open("/tmp/lexi-ai.log")
    {
        let _ = writeln!(f, "{ts} {message}");
    }
}

#[derive(Debug, Deserialize)]
pub struct AiRunRequest {
    pub text: String,
    pub api_base_url: String,
    pub api_key: String,
    pub model: String,
    pub prompt_template: String,
    pub output_mode: String,
    pub target_language: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
pub struct AiRunResult {
    pub output_text: String,
    pub translation: Option<TranslationResult>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct TranslationResult {
    pub word: String,
    pub translation: String,
    pub pos: String,
    pub definition: String,
    pub example: String,
}

#[derive(Debug, Deserialize)]
struct ChatCompletionResponse {
    choices: Vec<Choice>,
}

#[derive(Debug, Deserialize)]
struct Choice {
    message: Message,
}

#[derive(Debug, Deserialize)]
struct Message {
    content: String,
}

#[tauri::command]
pub async fn run_ai_prompt(request: AiRunRequest) -> Result<AiRunResult, String> {
    let text = request.text.trim();
    if text.is_empty() {
        return Err("Select or enter text first.".into());
    }

    if request.api_key.trim().is_empty() {
        return Err(
            "API key is not saved. Open Settings, enter the key, then click Save settings.".into(),
        );
    }

    let content = request_completion(&request, text).await?;
    if request.output_mode == "translation_json" {
        let translation = parse_translation(&content)
            .map_err(|error| format!("Could not parse translation JSON: {error}"))?;
        return Ok(AiRunResult {
            output_text: format_translation(&translation),
            translation: Some(translation),
        });
    }

    Ok(AiRunResult {
        output_text: clean_model_text(&content).to_string(),
        translation: None,
    })
}

async fn request_completion(request: &AiRunRequest, text: &str) -> Result<String, String> {
    let client = http_client();
    let url = format!(
        "{}/chat/completions",
        request.api_base_url.trim_end_matches('/')
    );
    let prompt = render_prompt(request, text);
    let system_message = if request.output_mode == "translation_json" {
        "Return compact JSON only. Do not wrap it in markdown."
    } else {
        "Follow the user prompt exactly. Return the answer directly without markdown fences unless requested."
    };

    let response = client
        .post(url)
        .header(CONTENT_TYPE, "application/json")
        .header(AUTHORIZATION, format!("Bearer {}", request.api_key))
        .json(&serde_json::json!({
            "model": request.model,
            "messages": [
                {"role": "system", "content": system_message},
                {"role": "user", "content": prompt}
            ],
            "temperature": 0.2
        }))
        .send()
        .await
        .map_err(|error| format!("AI request failed: {error}"))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("AI API returned {status}: {body}"));
    }

    let completion = response
        .json::<ChatCompletionResponse>()
        .await
        .map_err(|error| format!("Invalid AI response: {error}"))?;

    completion
        .choices
        .first()
        .map(|choice| choice.message.content.clone())
        .ok_or_else(|| "AI response did not include any choices.".to_string())
}

fn render_prompt(request: &AiRunRequest, text: &str) -> String {
    let target_language = request.target_language.as_deref().unwrap_or("");
    request
        .prompt_template
        .replace("{{targetLanguage}}", target_language)
        .replace("{{target_language}}", target_language)
        .replace("{{text}}", text)
}

fn parse_translation(content: &str) -> serde_json::Result<TranslationResult> {
    serde_json::from_str(clean_model_text(content))
}

fn clean_model_text(content: &str) -> &str {
    content
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim()
}

fn format_translation(result: &TranslationResult) -> String {
    format!(
        "### {}\n\n- **Word:** {}\n- **Translation:** {}\n- **Part of speech:** {}\n- **Definition:** {}\n- **Example:** {}",
        result.word,
        result.word,
        result.translation,
        result.pos,
        result.definition,
        result.example
    )
}

// ── Streaming ──────────────────────────────────────────────

#[derive(Clone, Serialize)]
struct StreamChunkEvent {
    run_id: String,
    chunk: Option<String>,
    done: bool,
    error: Option<String>,
    translation: Option<TranslationResult>,
}

/// Minimum spacing between chunk emits. Each emit is an IPC hop plus a full
/// React re-render (with ResizeObserver teardown) in the translation window —
/// emitting per SSE token caused 30-100 renders/sec. 40ms caps it at 25/sec,
/// still visually smooth. // ponytail: fixed interval; make adaptive if a
/// slow-typing effect is ever wanted.
const CHUNK_EMIT_INTERVAL: Duration = Duration::from_millis(40);

#[tauri::command]
pub async fn run_ai_prompt_stream(
    app: tauri::AppHandle,
    request: AiRunRequest,
    run_id: String,
) -> Result<String, String> {
    let text = request.text.trim().to_string();
    if text.is_empty() {
        return Err("Select or enter text first.".into());
    }
    if request.api_key.trim().is_empty() {
        return Err(
            "API key is not saved. Open Settings, enter the key, then click Save settings.".into(),
        );
    }

    // run_id is supplied by the caller so the frontend can register its event
    // listener BEFORE invoking — closing a race where a fast-failing stream
    // emitted its terminal event before the listener existed, leaving the UI
    // stuck on "Running...".
    log_ai(&format!(
        "spawn run_id={run_id} model={} mode={} base={}",
        request.model, request.output_mode, request.api_base_url
    ));

    let app_clone = app.clone();
    let run_id_clone = run_id.clone();
    tauri::async_runtime::spawn(async move {
        if let Err(error) = stream_completion(&app_clone, &run_id_clone, &request).await {
            log_ai(&format!("run_id={run_id_clone} stream returned error: {error}"));
            let _ = app_clone.emit("lexi://ai-stream-chunk", StreamChunkEvent {
                run_id: run_id_clone,
                chunk: None,
                done: true,
                error: Some(error),
                translation: None,
            });
        }
    });

    Ok(run_id)
}

async fn stream_completion(
    app: &tauri::AppHandle,
    run_id: &str,
    request: &AiRunRequest,
) -> Result<(), String> {
    use futures_util::StreamExt;

    let client = http_client();
    let url = format!("{}/chat/completions", request.api_base_url.trim_end_matches('/'));
    let prompt = render_prompt(request, request.text.trim());
    let system_message = if request.output_mode == "translation_json" {
        "Return compact JSON only. Do not wrap it in markdown."
    } else {
        "Follow the user prompt exactly. Return the answer directly without markdown fences unless requested."
    };

    log_ai(&format!("run_id={run_id} POST {url} model={}", request.model));
    let response = client
        .post(&url)
        .header(CONTENT_TYPE, "application/json")
        .header(AUTHORIZATION, format!("Bearer {}", request.api_key))
        .json(&serde_json::json!({
            "model": request.model,
            "messages": [
                {"role": "system", "content": system_message},
                {"role": "user", "content": prompt}
            ],
            "temperature": 0.2,
            "stream": true
        }))
        .send()
        .await
        .map_err(|error| {
            let msg = format!("AI request failed: {error}");
            log_ai(&format!("run_id={run_id} {msg}"));
            msg
        })?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        log_ai(&format!("run_id={run_id} non-success {status}: {}", body.chars().take(300).collect::<String>()));
        return Err(format!("AI API returned {status}: {body}"));
    }
    log_ai(&format!("run_id={run_id} response ok, streaming"));

    let is_translation_json = request.output_mode == "translation_json";
    let mut stream = response.bytes_stream();
    let mut buffer = String::new();
    let mut accumulated = String::new();
    let mut pending_emit = String::new();
    let mut last_emit = Instant::now();

    while let Some(chunk_result) = stream.next().await {
        let chunk = chunk_result.map_err(|error| format!("Stream read error: {error}"))?;
        buffer.push_str(&String::from_utf8_lossy(&chunk));

        while let Some(newline_pos) = buffer.find('\n') {
            let line = buffer[..newline_pos].trim().to_string();
            buffer = buffer[newline_pos + 1..].to_string();

            if !line.starts_with("data: ") {
                continue;
            }
            let data = &line[6..];
            if data == "[DONE]" {
                log_ai(&format!("run_id={run_id} [DONE] received"));
                continue;
            }

            if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(data) {
                if let Some(content) = parsed["choices"][0]["delta"]["content"].as_str() {
                    accumulated.push_str(content);

                    // For translation_json, don't stream raw JSON — accumulate silently
                    if !is_translation_json {
                        pending_emit.push_str(content);
                        if last_emit.elapsed() >= CHUNK_EMIT_INTERVAL {
                            let _ = app.emit("lexi://ai-stream-chunk", StreamChunkEvent {
                                run_id: run_id.to_string(),
                                chunk: Some(std::mem::take(&mut pending_emit)),
                                done: false,
                                error: None,
                                translation: None,
                            });
                            last_emit = Instant::now();
                        }
                    }
                }
            }
        }
    }
    log_ai(&format!(
        "run_id={run_id} stream ended, accumulated_len={}",
        accumulated.len()
    ));

    // Process any remaining buffer
    let remaining = buffer.trim();
    if remaining.starts_with("data: ") && &remaining[6..] != "[DONE]" {
        if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&remaining[6..]) {
            if let Some(content) = parsed["choices"][0]["delta"]["content"].as_str() {
                accumulated.push_str(content);
                if !is_translation_json {
                    pending_emit.push_str(content);
                }
            }
        }
    }

    // Flush any coalesced remainder before the terminal event
    if !is_translation_json && !pending_emit.is_empty() {
        let _ = app.emit("lexi://ai-stream-chunk", StreamChunkEvent {
            run_id: run_id.to_string(),
            chunk: Some(std::mem::take(&mut pending_emit)),
            done: false,
            error: None,
            translation: None,
        });
    }

    // Final done event
    if is_translation_json {
        let translation = parse_translation(&accumulated)
            .map_err(|error| format!("Could not parse translation JSON: {error}"))?;
        let formatted = format_translation(&translation);
        let _ = app.emit("lexi://ai-stream-chunk", StreamChunkEvent {
            run_id: run_id.to_string(),
            chunk: Some(formatted),
            done: true,
            error: None,
            translation: Some(translation),
        });
    } else {
        let cleaned = clean_model_text(&accumulated).to_string();
        let _ = app.emit("lexi://ai-stream-chunk", StreamChunkEvent {
            run_id: run_id.to_string(),
            chunk: Some(cleaned),
            done: true,
            error: None,
            translation: None,
        });
    }

    Ok(())
}
