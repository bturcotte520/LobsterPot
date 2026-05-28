/**
 * SessionBindingAdapter for the LobsterPot channel.
 *
 * When OpenClaw spawns a subagent with `thread: true`, this adapter:
 *   1. Creates a fresh conversation on the LobsterPot bridge
 *   2. Stores the binding in memory
 *   3. Returns a SessionBindingRecord so OpenClaw routes future delivery
 *      and inbound traffic to the bound conversation
 *
 * iOS sees a new conversation row appear via the bridge SSE stream.
 */

import type {
  SessionBindingAdapter,
  SessionBindingBindInput,
  SessionBindingRecord,
  SessionBindingUnbindInput,
  ConversationRef
} from "openclaw/plugin-sdk/conversation-runtime";
import { createId } from "@lobsterpot/shared";

/** Minimal interface our adapter needs from the bridge client. */
export interface BindingBridgeClient {
  /** POST /api/conversations on the bridge using the plugin's bridge token. */
  createConversation(input: {
    title: string;
    purpose?: string | null;
    kind?: "main" | "subagent" | "specialist" | "support" | "system";
    openclawSessionKey?: string | null;
    openclawAgentId?: string | null;
  }): Promise<{ id: string; title: string }>;
}

/** In-memory binding record. */
type StoredBinding = SessionBindingRecord & { boundAtMs: number };

export class LobsterPotBindingAdapter implements SessionBindingAdapter {
  readonly channel = "lobsterpot";
  readonly accountId: string;
  readonly capabilities = {
    placements: ["child" as const],
    bindSupported: true,
    unbindSupported: true
  };

  private readonly bySessionKey = new Map<string, StoredBinding>();
  private readonly byConversationId = new Map<string, StoredBinding>();

  constructor(
    accountId: string,
    private readonly bridge: BindingBridgeClient,
    private readonly logger: { info: (msg: string) => void; warn: (msg: string) => void; error: (msg: string) => void }
  ) {
    this.accountId = accountId;
  }

  /**
   * Create a new bridge conversation for a thread-bound subagent session.
   */
  bind = async (input: SessionBindingBindInput): Promise<SessionBindingRecord | null> => {
    if (input.targetKind !== "subagent") {
      return null;
    }

    const title = deriveTitle(input);
    const purpose = derivePurpose(input);

    let created: { id: string; title: string };
    try {
      created = await this.bridge.createConversation({
        title,
        purpose,
        kind: "subagent",
        openclawSessionKey: input.targetSessionKey,
        openclawAgentId: deriveAgentId(input.targetSessionKey)
      });
    } catch (err) {
      this.logger.error(`[lobsterpot] failed to create bound conversation: ${String(err)}`);
      return null;
    }

    const record: StoredBinding = {
      bindingId: createId(),
      targetSessionKey: input.targetSessionKey,
      targetKind: input.targetKind,
      conversation: {
        channel: this.channel,
        accountId: this.accountId,
        conversationId: created.id,
        parentConversationId: input.conversation.conversationId
      },
      status: "active",
      boundAt: Date.now(),
      boundAtMs: Date.now(),
      ...(input.ttlMs ? { expiresAt: Date.now() + input.ttlMs } : {}),
      metadata: { ...input.metadata, parentConversationId: input.conversation.conversationId }
    };

    this.bySessionKey.set(input.targetSessionKey, record);
    this.byConversationId.set(created.id, record);
    this.logger.info(
      `[lobsterpot] bound session ${shortKey(input.targetSessionKey)} -> conversation ${created.id} ("${title}")`
    );
    return record;
  };

  bindExistingConversation(input: {
    conversationId: string;
    targetSessionKey: string;
    targetKind?: "subagent" | "session";
    parentConversationId?: string | null;
    metadata?: Record<string, unknown>;
  }): SessionBindingRecord {
    const record: StoredBinding = {
      bindingId: createId(),
      targetSessionKey: input.targetSessionKey,
      targetKind: input.targetKind ?? "subagent",
      conversation: {
        channel: this.channel,
        accountId: this.accountId,
        conversationId: input.conversationId,
        ...(input.parentConversationId ? { parentConversationId: input.parentConversationId } : {})
      },
      status: "active",
      boundAt: Date.now(),
      boundAtMs: Date.now(),
      metadata: input.metadata ?? {}
    };
    this.bySessionKey.set(input.targetSessionKey, record);
    this.byConversationId.set(input.conversationId, record);
    this.logger.info(
      `[lobsterpot] bound existing session ${shortKey(input.targetSessionKey)} -> conversation ${input.conversationId}`
    );
    return record;
  }

  listBySession = (targetSessionKey: string): SessionBindingRecord[] => {
    const r = this.bySessionKey.get(targetSessionKey);
    return r ? [r] : [];
  };

  resolveByConversation = (ref: ConversationRef): SessionBindingRecord | null => {
    if (ref.channel !== this.channel) return null;
    return this.byConversationId.get(ref.conversationId) ?? null;
  };

  touch = (bindingId: string, at: number = Date.now()): void => {
    for (const r of this.bySessionKey.values()) {
      if (r.bindingId === bindingId) {
        r.boundAtMs = at;
        return;
      }
    }
  };

  unbind = async (input: SessionBindingUnbindInput): Promise<SessionBindingRecord[]> => {
    const removed: SessionBindingRecord[] = [];
    if (input.bindingId) {
      for (const [k, r] of this.bySessionKey) {
        if (r.bindingId === input.bindingId) {
          r.status = "ended";
          this.bySessionKey.delete(k);
          this.byConversationId.delete(r.conversation.conversationId);
          removed.push(r);
        }
      }
    } else if (input.targetSessionKey) {
      const r = this.bySessionKey.get(input.targetSessionKey);
      if (r) {
        r.status = "ended";
        this.bySessionKey.delete(input.targetSessionKey);
        this.byConversationId.delete(r.conversation.conversationId);
        removed.push(r);
      }
    }
    return removed;
  };
}

// ── Helpers ──────────────────────────────────────────────────────────────────

function deriveTitle(input: SessionBindingBindInput): string {
  const meta = input.metadata as Record<string, unknown> | undefined;
  const label = typeof meta?.["label"] === "string" ? (meta["label"] as string) : null;
  const taskName = typeof meta?.["taskName"] === "string" ? (meta["taskName"] as string) : null;
  if (label && label.trim()) return label.trim();
  if (taskName && taskName.trim()) return prettifyTaskName(taskName);
  return `Subagent ${shortKey(input.targetSessionKey)}`;
}

function derivePurpose(input: SessionBindingBindInput): string | null {
  const meta = input.metadata as Record<string, unknown> | undefined;
  const task = typeof meta?.["task"] === "string" ? (meta["task"] as string) : null;
  if (task) {
    return task.length > 240 ? task.slice(0, 237) + "…" : task;
  }
  return null;
}

function prettifyTaskName(taskName: string): string {
  return taskName
    .replace(/[_-]+/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase())
    .trim();
}

function shortKey(sessionKey: string): string {
  // session keys look like agent:<agentId>:subagent:<uuid>
  const parts = sessionKey.split(":");
  const last = parts[parts.length - 1] ?? sessionKey;
  return last.slice(0, 8);
}

function deriveAgentId(sessionKey: string): string | null {
  const match = /^agent:([^:]+):subagent:/.exec(sessionKey);
  return match?.[1] ?? null;
}
