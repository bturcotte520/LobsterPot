CREATE TABLE IF NOT EXISTS openclaw_instances (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  bridge_token_id TEXT NOT NULL UNIQUE,
  revoked_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (bridge_token_id) REFERENCES bridge_tokens(id)
);

ALTER TABLE conversations ADD COLUMN openclaw_instance_id TEXT;

CREATE INDEX IF NOT EXISTS idx_conversations_openclaw_instance ON conversations(openclaw_instance_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_openclaw_instances_token ON openclaw_instances(bridge_token_id);
