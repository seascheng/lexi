use reqwest::header::{AUTHORIZATION, CONTENT_TYPE};
use serde::{Deserialize, Serialize};

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
pub async fn run_ai_prompt(request: AiRunRequest) -> Result<AiRunResult, String> {
    let text = request.text.trim();
    if text.is_empty() {
        return Err("Select or enter text first.".into());
    }

    if request.api_key.trim().is_empty() {
        return Err("API key is not saved. Open Settings, enter the key, then click Save settings.".into());
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
    let client = reqwest::Client::new();
    let url = format!("{}/chat/completions", request.api_base_url.trim_end_matches('/'));
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
