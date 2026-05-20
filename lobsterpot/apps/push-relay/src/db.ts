import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { createId, nowIso, sha256 } from "@lobsterpot/shared";

type RegistrationRow = {
  id: string;
  handle: string;
  grant_hash: string;
  bridge_id: string;
  bundle_id: string;
  apns_device_token: string | null;
  environment: "sandbox" | "production";
  created_at: string;
  updated_at: string;
};

export type RegistrationCreated = {
  id: string;
  handle: string;
  grant: string;
  createdAt: string;
};

export type Registration = {
  id: string;
  handle: string;
  grantHash: string;
  bridgeId: string;
  bundleId: string;
  apnsDeviceToken: string | null;
  environment: "sandbox" | "production";
  createdAt: string;
};

const SCHEMA = `
CREATE TABLE IF NOT EXISTS registrations (
  id           TEXT PRIMARY KEY,
  handle       TEXT NOT NULL UNIQUE,
  grant_hash   TEXT NOT NULL,
  bridge_id    TEXT NOT NULL,
  bundle_id    TEXT NOT NULL,
  apns_device_token TEXT,
  environment  TEXT NOT NULL DEFAULT 'sandbox',
  created_at   TEXT NOT NULL,
  updated_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_registrations_handle ON registrations(handle);
`;

export class RelayDatabase {
  readonly db: Database.Database;

  constructor(path: string) {
    mkdirSync(dirname(path), { recursive: true });
    this.db = new Database(path);
    this.db.pragma("journal_mode = WAL");
    this.db.pragma("foreign_keys = ON");
    this.db.exec(SCHEMA);
  }

  close(): void { this.db.close(); }

  createRegistration(input: {
    bridgeId: string;
    bundleId: string;
    apnsDeviceToken?: string;
    environment: "sandbox" | "production";
  }): RegistrationCreated {
    const id = createId();
    const handle = `relay_${id.replaceAll("-", "")}`;
    const grant = `relaygrant_${Buffer.from(id).toString("base64url")}`;
    const now = nowIso();
    this.db.prepare(`
      INSERT INTO registrations (id, handle, grant_hash, bridge_id, bundle_id, apns_device_token, environment, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).run(id, handle, sha256(grant), input.bridgeId, input.bundleId, input.apnsDeviceToken ?? null, input.environment, now, now);
    return { id, handle, grant, createdAt: now };
  }

  findByHandle(handle: string): Registration | null {
    const row = this.db.prepare(`SELECT * FROM registrations WHERE handle = ?`).get(handle) as RegistrationRow | undefined;
    return row ? toRegistration(row) : null;
  }

  updateApnsToken(handle: string, apnsDeviceToken: string): void {
    this.db.prepare(`UPDATE registrations SET apns_device_token = ?, updated_at = ? WHERE handle = ?`).run(apnsDeviceToken, nowIso(), handle);
  }

  deleteByHandle(handle: string): void {
    this.db.prepare(`DELETE FROM registrations WHERE handle = ?`).run(handle);
  }
}

function toRegistration(row: RegistrationRow): Registration {
  return {
    id: row.id,
    handle: row.handle,
    grantHash: row.grant_hash,
    bridgeId: row.bridge_id,
    bundleId: row.bundle_id,
    apnsDeviceToken: row.apns_device_token,
    environment: row.environment,
    createdAt: row.created_at
  };
}
