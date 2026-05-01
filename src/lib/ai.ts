import { invoke } from "@tauri-apps/api/core";
import { writeText } from "@tauri-apps/plugin-clipboard-manager";
import type { AiFeature, AiRunResult, AppSettings } from "../types";
import { isTauriRuntime } from "./platform";

interface AiRunRequest {
  text: string;
  api_base_url: string;
  api_key: string;
  model: string;
  prompt_template: string;
  output_mode: string;
  target_language: string | null;
}

export async function runAiFeature(text: string, feature: AiFeature, settings: AppSettings): Promise<AiRunResult> {
  const trimmed = text.trim();
  if (!trimmed) throw new Error("Select or enter text first.");
  if (!settings.apiKey.trim()) {
    throw new Error("API key is not saved. Open Settings, enter the key, then click Save settings.");
  }
  if (!settings.apiBaseUrl.trim()) {
    throw new Error("API base URL is not saved.");
  }
  if (!settings.model.trim()) {
    throw new Error("Model is not saved.");
  }

  if (!isTauriRuntime()) return browserAiResult(trimmed, feature);

  const request: AiRunRequest = {
    text: trimmed,
    api_base_url: settings.apiBaseUrl,
    api_key: settings.apiKey,
    model: settings.model,
    prompt_template: feature.promptTemplate,
    output_mode: feature.outputMode,
    target_language: feature.targetLanguage || null,
  };

  const result = await invoke<{ output_text: string; translation?: AiRunResult["translation"] }>("run_ai_prompt", {
    request,
  });

  return {
    outputText: result.output_text,
    translation: result.translation ?? parseTranslationMarkdown(feature, result.output_text),
  };
}

export async function analyzeLearningPoint(
  selectedText: string,
  contextText: string,
  sourceFeature: AiFeature,
  settings: AppSettings,
): Promise<AiRunResult> {
  const promptTemplate = captureLearningPointPrompt(contextText, sourceFeature.name);
  return runAiFeature(selectedText, captureLearningPointFeature(sourceFeature, promptTemplate), settings);
}

export async function copyText(text: string) {
  if (isTauriRuntime()) {
    await writeText(text);
    return;
  }

  await navigator.clipboard.writeText(text);
}

export async function speakText(text: string) {
  const trimmed = text.trim();
  if (!trimmed) throw new Error("Nothing to speak.");

  if (isTauriRuntime()) {
    await invoke("speak_text", { text: trimmed });
    return;
  }

  const utterance = new SpeechSynthesisUtterance(trimmed);
  window.speechSynthesis.cancel();
  window.speechSynthesis.speak(utterance);
}

function browserAiResult(text: string, feature: AiFeature): AiRunResult {
  if (feature.id.startsWith("capture-learning-point")) {
    return {
      outputText: `### Learning point

- **Type:** phrase
- **Meaning:** Configure the desktop API to analyze "${text}".
- **Usage:** Use this action after selecting useful text in the popup.
- **Example:** I saved "${text}" as a learning point.
- **Note:** This is a local browser preview.`,
    };
  }

  if (feature.outputMode === "translation_json") {
    const translation = {
      word: text,
      translation: feature.targetLanguage.toLowerCase().includes("chinese")
        ? "配置 API 后显示翻译"
        : "Configure API to translate",
      pos: "phrase",
      definition: "A local preview result shown when the Tauri backend or API key is unavailable.",
      example: `Use "${text}" after configuring your OpenAI-compatible API.`,
    };
    return {
      outputText: `${translation.word} - ${translation.translation}\n${translation.definition}\n${translation.example}`,
      translation,
    };
  }

  if (feature.kind === "translation") {
    const translation = {
      word: text,
      translation: feature.targetLanguage.toLowerCase().includes("chinese")
        ? "配置 API 后显示翻译"
        : "Configure API to translate",
      pos: "phrase",
      definition: "A local preview result shown when the Tauri backend or API key is unavailable.",
      example: `Use "${text}" after configuring your OpenAI-compatible API.`,
    };
    return {
      outputText: `### ${translation.word}

- **Word:** ${translation.word}
- **Translation:** ${translation.translation}
- **Part of speech:** ${translation.pos}
- **Definition:** ${translation.definition}
- **Example:** ${translation.example}`,
      translation,
    };
  }

  return {
    outputText: `Configure the desktop API settings to run "${feature.name}" on:\n\n${text}`,
  };
}

function captureLearningPointFeature(sourceFeature: AiFeature, promptTemplate: string): AiFeature {
  return {
    id: `capture-learning-point-${sourceFeature.id}`,
    name: "Capture learning point",
    kind: "custom",
    promptTemplate,
    outputMode: "plain_text",
    enabled: true,
    sortOrder: 0,
    autoSaveToVocabulary: false,
    targetLanguage: sourceFeature.targetLanguage,
    reviewIntervalSeconds: 30,
    speechEnabled: false,
  };
}

function captureLearningPointPrompt(contextText: string, featureName: string) {
  return `Analyze the exact selected English text from the Englist popup.

Selected text:
{{text}}

Source feature:
${featureName}

Context:
${contextText.trim() || "(No extra context)"}

Rules:
- Treat the whole selected text as the learning point.
- Do not replace it with one word from inside the selected text.
- If the selected text is a sentence, analyze the sentence meaning, structure, and reusable pattern.
- If the selected text is a phrase, analyze the phrase as a complete expression.
- If the selected text is a single word, analyze the word.

Return concise Markdown only. Keep this exact label style when possible:

### Learning point
- **Type:** word / phrase / pattern
- **Meaning:** concise meaning in Chinese
- **Usage:** how to use it naturally
- **Example:** one natural English sentence
- **Note:** one short learning note`;
}

function parseTranslationMarkdown(feature: AiFeature, outputText: string): AiRunResult["translation"] {
  if (feature.kind !== "translation") return undefined;

  const word = markdownField(outputText, "Word") || markdownHeading(outputText);
  const translation = markdownField(outputText, "Translation");
  const pos = markdownField(outputText, "Part of speech") || markdownField(outputText, "POS");
  const definition = markdownField(outputText, "Definition");
  const example = markdownField(outputText, "Example");

  if (!word || !translation) return undefined;

  return {
    word,
    translation,
    pos,
    definition,
    example,
  };
}

function markdownField(outputText: string, label: string) {
  const escapedLabel = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(`(?:^|\\n)\\s*(?:[-*]\\s*)?\\*\\*${escapedLabel}:\\*\\*\\s*([^\\n]+)`, "i");
  return pattern.exec(outputText)?.[1]?.trim() ?? "";
}

function markdownHeading(outputText: string) {
  return /^#{1,3}\s+(.+)$/m.exec(outputText)?.[1]?.trim() ?? "";
}
