ALTER TABLE conversations ADD COLUMN openclaw_session_key TEXT;
ALTER TABLE conversations ADD COLUMN openclaw_agent_id TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_conversations_openclaw_session_key
  ON conversations(openclaw_session_key)
  WHERE openclaw_session_key IS NOT NULL;
