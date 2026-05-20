-- Relay registration: the bridge registers once with the push relay and stores
-- the handle + grant (raw) so it can call /api/send for every outbound message.
CREATE TABLE IF NOT EXISTS relay_registrations (
  id TEXT PRIMARY KEY,
  relay_url TEXT NOT NULL,
  relay_handle TEXT NOT NULL UNIQUE,
  relay_grant TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Store the latest APNs device token per device so the bridge can forward it
-- to the relay when the iOS app registers for push notifications.
ALTER TABLE devices ADD COLUMN apns_token TEXT NOT NULL DEFAULT '';
ALTER TABLE devices ADD COLUMN apns_environment TEXT NOT NULL DEFAULT 'sandbox';
