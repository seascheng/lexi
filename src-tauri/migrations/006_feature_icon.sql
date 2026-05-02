ALTER TABLE ai_features ADD COLUMN icon TEXT NOT NULL DEFAULT 'wand';
UPDATE ai_features SET icon = 'languages' WHERE id = 'translation';
UPDATE ai_features SET icon = 'book-plus' WHERE id = 'review';
