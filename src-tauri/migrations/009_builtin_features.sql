-- Add is_builtin flag to ai_features
ALTER TABLE ai_features ADD COLUMN is_builtin INTEGER NOT NULL DEFAULT 0;

-- Mark existing built-in features
UPDATE ai_features SET is_builtin = 1 WHERE id = 'translation';
UPDATE ai_features SET is_builtin = 1 WHERE id = 'extract';

-- Migrate existing user-created Rewrite/AI to builtin IDs (preserve their prompts)
UPDATE ai_features SET id = 'rewrite', is_builtin = 1 WHERE name = 'Rewrite' AND kind = 'custom' AND id != 'rewrite';
UPDATE ai_features SET id = 'ai', is_builtin = 1 WHERE name = 'AI' AND kind = 'custom' AND id != 'ai';

-- Remove any duplicate rows left behind after ID migration
DELETE FROM ai_features WHERE name = 'Rewrite' AND kind = 'custom' AND id != 'rewrite';
DELETE FROM ai_features WHERE name = 'AI' AND kind = 'custom' AND id != 'ai';

-- Insert Extract (may not exist for users who only had it injected at runtime)
INSERT OR IGNORE INTO ai_features (id, name, kind, prompt_template, output_mode, enabled, sort_order, auto_save_to_vocabulary, target_language, speech_enabled, icon, is_builtin, created_at, updated_at)
VALUES ('extract', 'Extract', 'custom',
'Analyze text as ONE learning point.Use Chinese.

<<<TEXT>>>
{{text}}
<<<END>>>

Classify: word / phrase / sentence

- word/phrase: meaning + usage
- sentence: meaning + structure + pattern

Give 1 example. Keep concise.

Return Markdown:

### Learning point
- **Type:**
- **Meaning:**
- **Usage:**
- **Example:**
- **Note:**',
'plain_text', 1, 10, 0, 'Chinese', 0, 'highlighter', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);

-- Insert Rewrite
INSERT OR IGNORE INTO ai_features (id, name, kind, prompt_template, output_mode, enabled, sort_order, auto_save_to_vocabulary, target_language, speech_enabled, icon, is_builtin, created_at, updated_at)
VALUES ('rewrite', 'Rewrite', 'custom',
'Rewrite sentences into idiomatic English and flag issues.Use Chinese.

<<<TEXT>>>
{{text}}
<<<END>>>

For each sentence:
- rewrite naturally
- list unidiomatic parts
- brief reason

Return Markdown list:

- Improved: ...
- Issues:
  - ...
- Explanation:
  - ...',
'plain_text', 1, 40, 0, 'Chinese', 0, 'wand', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);

-- Insert AI
INSERT OR IGNORE INTO ai_features (id, name, kind, prompt_template, output_mode, enabled, sort_order, auto_save_to_vocabulary, target_language, speech_enabled, icon, is_builtin, created_at, updated_at)
VALUES ('ai', 'AI', 'custom',
'Answer the questions in the following text or explain this concept in a popular, detailed, and organized manner.Use Chinese.

<<<TEXT>>>
{{text}}
<<<END>>>',
'plain_text', 1, 60, 0, 'Chinese', 0, 'sparkles', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
