-- Pairing codes: short-lived codes exchanged during device setup
CREATE TABLE IF NOT EXISTS pairing_codes (
  id TEXT PRIMARY KEY,
  code TEXT NOT NULL UNIQUE,
  used_at TEXT,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_pairing_codes_code ON pairing_codes(code);
CREATE INDEX IF NOT EXISTS idx_pairing_codes_expires ON pairing_codes(expires_at);

-- Add pairing_code_id FK to devices so we can trace how a device was provisioned
ALTER TABLE devices ADD COLUMN pairing_code_id TEXT REFERENCES pairing_codes(id);
