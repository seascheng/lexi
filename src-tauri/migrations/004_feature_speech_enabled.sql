ALTER TABLE ai_features ADD COLUMN speech_enabled INTEGER NOT NULL DEFAULT 0;
UPDATE ai_features SET speech_enabled = 1 WHERE kind IN ('translation', 'review');
