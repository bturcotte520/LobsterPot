import Database from "better-sqlite3";
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Attachment, Conversation, Message, PublicBridgeEvent } from "@lobsterpot/protocol";
import { createId, createToken, nowIso, sha256 } from "@lobsterpot/shared";

const currentDir = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(currentDir, "../migrations");

type DeviceRow = {
  id: string;
  name: string | null;
  public_key: string | null;
  token_hash: string;
  pairing_code_id: string | null;
  apns_token: string;
  apns_environment: string;
  revoked_at: string | null;
  created_at: string;
  updated_at: string;
};

type RelayRegistrationRow = {
  id: string;
  relay_url: string;
  relay_handle: string;
  relay_grant: string;
  created_at: string;
  updated_at: string;
};

type PairingCodeRow = {
  id: string;
  code: string;
  code_challenge: string | null;
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
  openclaw_session_key: string | null;
  openclaw_agent_id: string | null;
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

type AttachmentRow = {
  id: string;
  filename: string;
  content_type: string;
  byte_size: number;
  storage_path: string;
  created_at: string;
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
      try {
        this.db.exec(sql);
      } catch (err) {
        // ALTER TABLE … ADD COLUMN throws if column already exists; swallow those safely
        const msg = (err as Error).message ?? "";
        if (!msg.includes("duplicate column name")) throw err;
      }
    }
  }

  // ── Bridge tokens ────────────────────────────────────────────────────────

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

  // ── Conversations ────────────────────────────────────────────────────────

  listConversations(input: { archived?: boolean } = {}): Conversation[] {
    const archived = input.archived ?? false;
    const rows = this.db.prepare(`
      SELECT * FROM conversations
      WHERE ${archived ? "archived_at IS NOT NULL" : "archived_at IS NULL"}
      ORDER BY CASE WHEN kind = 'main' THEN 1 ELSE 0 END DESC, pinned DESC, updated_at DESC
    `).all() as ConversationRow[];
    return rows.map(toConversation);
  }

  search(input: { query: string; includeArchived?: boolean; limit?: number }): { conversations: Conversation[]; messages: Message[] } {
    const q = `%${input.query.trim().replace(/[\\%_]/g, "\\$&")}%`;
    const limit = input.limit ?? 50;
    const includeArchived = input.includeArchived ?? false;
    const archivedClause = includeArchived ? "" : "AND c.archived_at IS NULL";
    const conversationRows = this.db.prepare(`
      SELECT DISTINCT c.* FROM conversations c
      LEFT JOIN messages m ON m.conversation_id = c.id
      WHERE (c.title LIKE ? ESCAPE '\\' OR c.purpose LIKE ? ESCAPE '\\' OR m.content LIKE ? ESCAPE '\\')
        ${archivedClause}
      ORDER BY CASE WHEN c.kind = 'main' THEN 1 ELSE 0 END DESC, c.pinned DESC, c.updated_at DESC
      LIMIT ?
    `).all(q, q, q, limit) as ConversationRow[];
    const messageRows = this.db.prepare(`
      SELECT m.* FROM messages m
      JOIN conversations c ON c.id = m.conversation_id
      WHERE m.content LIKE ? ESCAPE '\\'
        ${archivedClause}
      ORDER BY m.created_at DESC
      LIMIT ?
    `).all(q, limit) as MessageRow[];
    return {
      conversations: conversationRows.map(toConversation),
      messages: this.attachAttachments(messageRows.map(toMessage))
    };
  }

  getConversation(id: string): Conversation | null {
    const row = this.db.prepare(`SELECT * FROM conversations WHERE id = ?`).get(id) as ConversationRow | undefined;
    return row ? toConversation(row) : null;
  }

  createConversation(input: {
    title: string;
    purpose?: string | null;
    kind?: Conversation["kind"];
    openclawSessionKey?: string | null;
    openclawAgentId?: string | null;
  }): Conversation {
    if (input.openclawSessionKey) {
      const existing = this.getConversationByOpenClawSessionKey(input.openclawSessionKey);
      if (existing) return existing;
    }
    const id = createId();
    const now = nowIso();
    this.db.prepare(`
      INSERT INTO conversations (id, title, purpose, kind, openclaw_session_key, openclaw_agent_id, pinned, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?)
    `).run(id, input.title, input.purpose ?? null, input.kind ?? "specialist", input.openclawSessionKey ?? null, input.openclawAgentId ?? null, now, now);
    return this.getConversation(id)!;
  }

  getConversationByOpenClawSessionKey(sessionKey: string): Conversation | null {
    const row = this.db.prepare(`SELECT * FROM conversations WHERE openclaw_session_key = ? LIMIT 1`).get(sessionKey) as ConversationRow | undefined;
    return row ? toConversation(row) : null;
  }

  updateConversation(id: string, input: {
    title?: string;
    purpose?: string | null;
    pinned?: boolean;
    archived?: boolean;
  }): Conversation | null {
    const current = this.getConversation(id);
    if (!current) return null;
    const next = {
      title: input.title ?? current.title,
      purpose: input.purpose === undefined ? current.purpose : input.purpose,
      pinned: input.pinned === undefined ? current.pinned : input.pinned,
      archivedAt: input.archived === undefined ? current.archivedAt : (input.archived ? nowIso() : null)
    };
    this.db.prepare(`
      UPDATE conversations SET title = ?, purpose = ?, pinned = ?, archived_at = ?, updated_at = ? WHERE id = ?
    `).run(next.title, next.purpose ?? null, next.pinned ? 1 : 0, next.archivedAt ?? null, nowIso(), id);
    return this.getConversation(id);
  }

  deleteConversation(id: string): boolean {
    const current = this.getConversation(id);
    if (!current || current.kind === "main") return false;
    const tx = this.db.transaction(() => {
      this.db.prepare(`DELETE FROM messages WHERE conversation_id = ?`).run(id);
      this.db.prepare(`DELETE FROM events WHERE conversation_id = ?`).run(id);
      this.db.prepare(`DELETE FROM conversations WHERE id = ?`).run(id);
    });
    tx();
    return true;
  }

  // ── Messages ─────────────────────────────────────────────────────────────

  listMessages(conversationId: string): Message[] {
    const rows = this.db.prepare(`
      SELECT * FROM messages WHERE conversation_id = ? ORDER BY created_at ASC
    `).all(conversationId) as MessageRow[];
    return this.attachAttachments(rows.map(toMessage));
  }

  createMessage(input: {
    conversationId: string;
    role: Message["role"];
    content: string;
    status: Message["status"];
    sourceEventId?: string | null;
    attachmentIds?: string[];
  }): Message {
    const id = createId();
    const now = nowIso();
    const tx = this.db.transaction(() => {
      this.db.prepare(`
        INSERT INTO messages (id, conversation_id, source_event_id, role, content, status, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      `).run(id, input.conversationId, input.sourceEventId ?? null, input.role, input.content, input.status, now, now);
      for (const [index, attachmentId] of (input.attachmentIds ?? []).entries()) {
        this.db.prepare(`
          INSERT OR IGNORE INTO message_attachments (message_id, attachment_id, position)
          VALUES (?, ?, ?)
        `).run(id, attachmentId, index);
      }
    });
    tx();
    return this.attachAttachments([toMessage(this.db.prepare(`SELECT * FROM messages WHERE id = ?`).get(id) as MessageRow)])[0]!;
  }

  createAttachment(input: {
    filename: string;
    contentType: string;
    byteSize: number;
    storagePath: string;
  }): Attachment {
    const id = createId();
    const now = nowIso();
    this.db.prepare(`
      INSERT INTO attachments (id, filename, content_type, byte_size, storage_path, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
    `).run(id, input.filename, input.contentType, input.byteSize, input.storagePath, now);
    return toAttachment(this.db.prepare(`SELECT * FROM attachments WHERE id = ?`).get(id) as AttachmentRow);
  }

  getAttachment(id: string): (Attachment & { storagePath: string }) | null {
    const row = this.db.prepare(`SELECT * FROM attachments WHERE id = ?`).get(id) as AttachmentRow | undefined;
    return row ? toAttachmentWithStoragePath(row) : null;
  }

  getAttachments(ids: string[]): Attachment[] {
    if (ids.length === 0) return [];
    const placeholders = ids.map(() => "?").join(", ");
    const rows = this.db.prepare(`SELECT * FROM attachments WHERE id IN (${placeholders})`).all(...ids) as AttachmentRow[];
    return rows.map(toAttachment);
  }

  private attachAttachments(messages: Message[]): Message[] {
    if (messages.length === 0) return messages;
    const messageIds = messages.map((message) => message.id);
    const placeholders = messageIds.map(() => "?").join(", ");
    const rows = this.db.prepare(`
      SELECT ma.message_id, a.* FROM message_attachments ma
      JOIN attachments a ON a.id = ma.attachment_id
      WHERE ma.message_id IN (${placeholders})
      ORDER BY ma.message_id, ma.position ASC
    `).all(...messageIds) as (AttachmentRow & { message_id: string })[];
    const byMessage = new Map<string, Attachment[]>();
    for (const row of rows) {
      const list = byMessage.get(row.message_id) ?? [];
      list.push(toAttachment(row));
      byMessage.set(row.message_id, list);
    }
    return messages.map((message) => ({ ...message, attachments: byMessage.get(message.id) ?? [] }));
  }

  // ── Events ───────────────────────────────────────────────────────────────

  recordEvent(input: {
    direction: "in" | "out";
    type: string;
    conversationId?: string | null;
    payload: unknown;
  }): PublicBridgeEvent {
    const id = createId();
    const now = nowIso();
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

  listEventsAfter(cursor?: string | null, limit = 100): PublicBridgeEvent[] {
    const rows = cursor
      ? this.db.prepare(`SELECT * FROM events WHERE cursor > ? ORDER BY cursor ASC LIMIT ?`).all(cursor, limit) as EventRow[]
      : this.db.prepare(`SELECT * FROM events ORDER BY cursor DESC LIMIT ?`).all(limit) as EventRow[];
    return rows.sort((a, b) => a.cursor.localeCompare(b.cursor)).map(toEvent);
  }

  // ── Device auth ──────────────────────────────────────────────────────────

  createPairingCode(codeChallenge: string): PairingStarted {
    const id = createId();
    const code = Math.random().toString(36).slice(2, 10).toUpperCase();
    const expiresAt = new Date(Date.now() + 10 * 60_000).toISOString();
    const createdAt = nowIso();
    this.db.prepare(`
      INSERT INTO pairing_codes (id, code, code_challenge, expires_at, created_at)
      VALUES (?, ?, ?, ?, ?)
    `).run(id, code, codeChallenge, expiresAt, createdAt);
    return { id, code, expiresAt };
  }

  consumePairingCode(code: string, codeVerifier: string): PairingCodeRow | null {
    const row = this.db.prepare(`
      SELECT * FROM pairing_codes
      WHERE code = ? AND used_at IS NULL AND expires_at > ?
    `).get(code, nowIso()) as PairingCodeRow | undefined;
    if (!row) return null;
    if (row.code_challenge && sha256(codeVerifier) !== row.code_challenge) return null;
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

  getDeviceById(id: string): DeviceRow | null {
    return this.db.prepare(`SELECT * FROM devices WHERE id = ? AND revoked_at IS NULL`).get(id) as DeviceRow | undefined ?? null;
  }

  updateDeviceApnsToken(deviceId: string, apnsToken: string, environment: "sandbox" | "production"): void {
    this.db.prepare(`
      UPDATE devices SET apns_token = ?, apns_environment = ?, updated_at = ? WHERE id = ?
    `).run(apnsToken, environment, nowIso(), deviceId);
  }

  // ── Push relay ───────────────────────────────────────────────────────────

  getRelayRegistration(): RelayRegistrationRow | null {
    return this.db.prepare(`SELECT * FROM relay_registrations LIMIT 1`).get() as RelayRegistrationRow | undefined ?? null;
  }

  upsertRelayRegistration(input: { url: string; handle: string; grant: string }): void {
    const now = nowIso();
    this.db.prepare(`
      INSERT INTO relay_registrations (id, relay_url, relay_handle, relay_grant, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(relay_handle) DO UPDATE SET
        relay_url = excluded.relay_url,
        relay_grant = excluded.relay_grant,
        updated_at = excluded.updated_at
    `).run(createId(), input.url, input.handle, input.grant, now, now);
  }
}

// ── Row → domain mappers ────────────────────────────────────────────────────

function toConversation(row: ConversationRow): Conversation {
  return {
    id: row.id,
    title: row.kind === "main" ? "Main Agent" : row.title,
    purpose: row.purpose,
    kind: row.kind,
    openclawSessionKey: row.openclaw_session_key,
    openclawAgentId: row.openclaw_agent_id,
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
    attachments: [],
    createdAt: row.created_at,
    updatedAt: row.updated_at
  };
}

function toAttachment(row: AttachmentRow): Attachment {
  return {
    id: row.id,
    filename: row.filename,
    contentType: row.content_type,
    byteSize: row.byte_size,
    url: `/api/attachments/${row.id}`,
    createdAt: row.created_at
  };
}

function toAttachmentWithStoragePath(row: AttachmentRow): Attachment & { storagePath: string } {
  return {
    ...toAttachment(row),
    storagePath: row.storage_path
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
