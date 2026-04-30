use reqwest::header::{AUTHORIZATION, CONTENT_TYPE};
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct TranslateRequest {
    pub text: String,
    pub api_base_url: String,
    pub api_key: String,
    pub model: String,
    pub target_language: String,
    pub prompt_template: String,
}

#[derive(Debug, Deserialize, Serialize)]
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
pub async fn translate_text(request: TranslateRequest) -> Result<TranslationResult, String> {
    let text = request.text.trim();
    if text.is_empty() {
        return Err("Select or enter text to translate.".into());
    }

    if request.api_key.trim().is_empty() {
        return Err("API key is not saved. Open Settings, enter the key, then click Save settings.".into());
    }

    let client = reqwest::Client::new();
    let url = format!("{}/chat/completions", request.api_base_url.trim_end_matches('/'));
    let prompt = request
        .prompt_template
        .replace("{{targetLanguage}}", &request.target_language)
        .replace("{{text}}", text);

    let response = client
        .post(url)
        .header(CONTENT_TYPE, "application/json")
        .header(AUTHORIZATION, format!("Bearer {}", request.api_key))
        .json(&serde_json::json!({
            "model": request.model,
            "messages": [
                {"role": "system", "content": "Return compact JSON only. Do not wrap it in markdown."},
                {"role": "user", "content": prompt}
            ],
            "temperature": 0.2
        }))
        .send()
        .await
        .map_err(|error| format!("Translation request failed: {error}"))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        return Err(format!("Translation API returned {status}: {body}"));
    }

    let completion = response
        .json::<ChatCompletionResponse>()
        .await
        .map_err(|error| format!("Invalid translation response: {error}"))?;

    let content = completion
        .choices
        .first()
        .map(|choice| choice.message.content.as_str())
        .ok_or_else(|| "Translation response did not include any choices.".to_string())?;

    parse_translation(content).map_err(|error| format!("Could not parse translation JSON: {error}"))
}

fn parse_translation(content: &str) -> serde_json::Result<TranslationResult> {
    let cleaned = content
        .trim()
        .trim_start_matches("```json")
        .trim_start_matches("```")
        .trim_end_matches("```")
        .trim();
    serde_json::from_str(cleaned)
}
