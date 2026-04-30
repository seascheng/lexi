CREATE TABLE IF NOT EXISTS ai_features (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,
  prompt_template TEXT NOT NULL,
  output_mode TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  sort_order INTEGER NOT NULL DEFAULT 0,
  auto_save_to_vocabulary INTEGER NOT NULL DEFAULT 0,
  target_language TEXT,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_ai_features_enabled_sort ON ai_features(enabled, sort_order);
