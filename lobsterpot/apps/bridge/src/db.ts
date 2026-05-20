import Database from "better-sqlite3";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Conversation, Message, PublicBridgeEvent } from "@lobsterpot/protocol";
import { createId, createToken, nowIso, sha256 } from "@lobsterpot/shared";

const currentDir = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(currentDir, "../migrations");

type DeviceRow = {
  id: string;
  name: string | null;
  public_key: string | null;
  token_hash: string;
  pairing_code_id: string | null;
  revoked_at: string | null;
  created_at: string;
  updated_at: string;
};

type PairingCodeRow = {
  id: string;
  code: string;
  used_at: string | null;
  expires_at: string;
  created_at: string;
};

type BridgeTokenRow = {
  id: string;
  token_hash: string;
  label: string | null;
  revoked_at: string | null;
  created_at: string;
  updated_at: string;
};

type ConversationRow = {
  id: string;
  title: string;
  purpose: string | null;
  kind: Conversation["kind"];
  pinned: 0 | 1;
  archived_at: string | null;
  created_at: string;
  updated_at: string;
};

type MessageRow = {
  id: string;
  conversation_id: string;
  source_event_id: string | null;
  role: Message["role"];
  content: string;
  status: Message["status"];
  created_at: string;
  updated_at: string;
};

type EventRow = {
  id: string;
  cursor: string;
  direction: string;
  type: string;
  conversation_id: string | null;
  payload_json: string;
  created_at: string;
};

export type BridgeTokenCreated = {
  id: string;
  token: string;
  createdAt: string;
};

export type DeviceCreated = {
  id: string;
  token: string;
  createdAt: string;
};

export type PairingStarted = {
  id: string;
  code: string;
  expiresAt: string;
};


export class BridgeDatabase {
  readonly db: Database.Database;

  constructor(path: string) {
    this.db = new Database(path);
    this.db.pragma("journal_mode = WAL");
    this.db.pragma("foreign_keys = ON");
    this.migrate();
  }

  close(): void {
    this.db.close();
  }

  migrate(): void {
    const files = readdirSync(migrationsDir)
      .filter((f) => f.endsWith(".sql"))
      .sort();
    for (const file of files) {
      const sql = readFileSync(join(migrationsDir, file), "utf8");
      // Wrap each migration in a savepoint so partial failures are isolated
      try {
        this.db.exec(sql);
      } catch (err) {
        // ALTER TABLE … ADD COLUMN throws if column already exists; swallow those safely
        const msg = (err as Error).message ?? "";
        if (!msg.includes("duplicate column name")) throw err;
      }
    }
  }

  createBridgeToken(label?: string): BridgeTokenCreated {
    const id = createId();
    const token = createToken("lobsterpot");
    const createdAt = nowIso();
    this.db.prepare(`
      INSERT INTO bridge_tokens (id, token_hash, label, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?)
    `).run(id, sha256(token), label ?? null, createdAt, createdAt);
    return { id, token, createdAt };
  }

  validateBridgeToken(token: string): BridgeTokenRow | null {
    return this.db.prepare(`
      SELECT * FROM bridge_tokens
      WHERE token_hash = ? AND revoked_at IS NULL
      LIMIT 1
    `).get(sha256(token)) as BridgeTokenRow | undefined ?? null;
  }

  upsertPluginConnection(input: {
    id: string;
    bridgeTokenId: string;
    instanceId: string;
    status: "connected" | "stale";
    capabilities: string[];
  }): void {
    const now = nowIso();
    this.db.prepare(`
      INSERT INTO plugin_connections (id, bridge_token_id, instance_id, status, last_seen_at, capabilities_json, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        instance_id = excluded.instance_id,
        status = excluded.status,
        last_seen_at = excluded.last_seen_at,
        capabilities_json = excluded.capabilities_json,
        updated_at = excluded.updated_at
    `).run(input.id, input.bridgeTokenId, input.instanceId, input.status, now, JSON.stringify(input.capabilities), now, now);
  }

  markPluginStale(connectionId: string): void {
    this.db.prepare(`
      UPDATE plugin_connections SET status = 'stale', updated_at = ? WHERE id = ?
    `).run(nowIso(), connectionId);
  }

  listConversations(): Conversation[] {
    const rows = this.db.prepare(`
      SELECT * FROM conversations WHERE archived_at IS NULL ORDER BY pinned DESC, updated_at DESC
    `).all() as ConversationRow[];
    return rows.map(toConversation);
  }

  getConversation(id: string): Conversation | null {
    const row = this.db.prepare(`SELECT * FROM conversations WHERE id = ?`).get(id) as ConversationRow | undefined;
    return row ? toConversation(row) : null;
  }

  createConversation(input: { title: string; purpose?: string | null; kind?: Conversation["kind"] }): Conversation {
    const id = createId();
    const now = nowIso();
    this.db.prepare(`
      INSERT INTO conversations (id, title, purpose, kind, pinned, created_at, updated_at)
      VALUES (?, ?, ?, ?, 0, ?, ?)
    `).run(id, input.title, input.purpose ?? null, input.kind ?? "specialist", now, now);
    return this.getConversation(id)!;
  }

  updateConversation(id: string, input: { title?: string; purpose?: string | null; pinned?: boolean; archived?: boolean }): Conversation | null {
    const current = this.getConversation(id);
    if (!current) return null;
    const next = {
      title: input.title ?? current.title,
      purpose: input.purpose === undefined ? current.purpose : input.purpose,
      pinned: input.pinned === undefined ? current.pinned : input.pinned,
      archivedAt: input.archived ? nowIso() : current.archivedAt
    };
    this.db.prepare(`
      UPDATE conversations SET title = ?, purpose = ?, pinned = ?, archived_at = ?, updated_at = ? WHERE id = ?
    `).run(next.title, next.purpose ?? null, next.pinned ? 1 : 0, next.archivedAt ?? null, nowIso(), id);
    return this.getConversation(id);
  }

  listMessages(conversationId: string): Message[] {
    const rows = this.db.prepare(`
      SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at ASC
    `).all(conversationId) as MessageRow[];
    return rows.map(toMessage);
  }

  createMessage(input: {
    conversationId: string;
    role: Message["role"];
    content: string;
    status: Message["status"];
    sourceEventId?: string | null;
  }): Message {
    const id = createId();
    const now = nowIso();
    this.db.prepare(`
      INSERT INTO messages (id, conversation_id, source_event_id, role, content, status, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `).run(id, input.conversationId, input.sourceEventId ?? null, input.role, input.content, input.status, now, now);
    return toMessage(this.db.prepare(`SELECT * FROM messages WHERE id = ?`).get(id) as MessageRow);
  }

  recordEvent(input: { direction: "in" | "out"; type: string; conversationId?: string | null; payload: unknown }): PublicBridgeEvent {
    const id = createId();
    const now = nowIso();
    // Insert with a placeholder cursor; use the SQLite ROWID (auto-increment) for
    // strict monotonic ordering even when multiple events land in the same millisecond.
    const info = this.db.prepare(`
      INSERT INTO events (id, cursor, direction, type, conversation_id, payload_json, created_at)
      VALUES (?, '', ?, ?, ?, ?, ?)
    `).run(id, input.direction, input.type, input.conversationId ?? null, JSON.stringify(input.payload), now);
    const cursor = String((info as { lastInsertRowid: number }).lastInsertRowid).padStart(20, "0");
    this.db.prepare(`UPDATE events SET cursor = ? WHERE id = ?`).run(cursor, id);
    return {
      id,
      cursor,
      type: input.type,
      conversationId: input.conversationId ?? null,
      payload: input.payload,
      createdAt: now
    };
  }

  // ── Device auth ──────────────────────────────────────────────────────────

  createPairingCode(): PairingStarted {
    const id = createId();
    const code = Math.random().toString(36).slice(2, 10).toUpperCase();
    const expiresAt = new Date(Date.now() + 10 * 60_000).toISOString();
    const createdAt = nowIso();
    this.db.prepare(`
      INSERT INTO pairing_codes (id, code, expires_at, created_at)
      VALUES (?, ?, ?, ?)
    `).run(id, code, expiresAt, createdAt);
    return { id, code, expiresAt };
  }

  consumePairingCode(code: string): PairingCodeRow | null {
    const row = this.db.prepare(`
      SELECT * FROM pairing_codes
      WHERE code = ? AND used_at IS NULL AND expires_at > ?
    `).get(code, nowIso()) as PairingCodeRow | undefined;
    if (!row) return null;
    this.db.prepare(`UPDATE pairing_codes SET used_at = ? WHERE id = ?`).run(nowIso(), row.id);
    return row;
  }

  createDevice(pairingCodeId: string): DeviceCreated {
    const id = createId();
    const token = createToken("device");
    const now = nowIso();
    this.db.prepare(`
      INSERT INTO devices (id, token_hash, pairing_code_id, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?)
    `).run(id, sha256(token), pairingCodeId, now, now);
    return { id, token, createdAt: now };
  }

  validateDeviceToken(token: string): DeviceRow | null {
    return this.db.prepare(`
      SELECT * FROM devices WHERE token_hash = ? AND revoked_at IS NULL LIMIT 1
    `).get(sha256(token)) as DeviceRow | undefined ?? null;
  }

  revokeDevice(id: string): void {
    this.db.prepare(`UPDATE devices SET revoked_at = ?, updated_at = ? WHERE id = ?`).run(nowIso(), nowIso(), id);
  }

  listEventsAfter(cursor?: string | null, limit = 100): PublicBridgeEvent[] {
    const rows = cursor
      ? this.db.prepare(`SELECT * FROM events WHERE cursor > ? ORDER BY cursor ASC LIMIT ?`).all(cursor, limit) as EventRow[]
      : this.db.prepare(`SELECT * FROM events ORDER BY cursor DESC LIMIT ?`).all(limit) as EventRow[];
    return rows.sort((a, b) => a.cursor.localeCompare(b.cursor)).map(toEvent);
  }
}

function toConversation(row: ConversationRow): Conversation {
  return {
    id: row.id,
    title: row.title,
    purpose: row.purpose,
    kind: row.kind,
    pinned: row.pinned === 1,
    archivedAt: row.archived_at,
    createdAt: row.created_at,
    updatedAt: row.updated_at
  };
}

function toMessage(row: MessageRow): Message {
  return {
    id: row.id,
    conversationId: row.conversation_id,
    sourceEventId: row.source_event_id,
    role: row.role,
    content: row.content,
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at
  };
}

function toEvent(row: EventRow): PublicBridgeEvent {
  return {
    id: row.id,
    cursor: row.cursor,
    type: row.type,
    conversationId: row.conversation_id,
    payload: JSON.parse(row.payload_json) as unknown,
    createdAt: row.created_at
  };
}
