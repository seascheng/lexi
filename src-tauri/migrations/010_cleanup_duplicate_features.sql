-- Cleanup duplicate Rewrite/AI features left by the first version of migration 9
DELETE FROM ai_features WHERE name = 'Rewrite' AND kind = 'custom' AND id != 'rewrite';
DELETE FROM ai_features WHERE name = 'AI' AND kind = 'custom' AND id != 'ai';
