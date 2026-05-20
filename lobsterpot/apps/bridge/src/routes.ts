import { Hono } from "hono";
import { streamSSE } from "hono/streaming";
import { z } from "zod";
import { inboundMessageSchema } from "@lobsterpot/protocol";
import { createId, nowIso, normalizeBaseUrl } from "@lobsterpot/shared";
import type { BridgeConfig } from "./config.js";
import type { BridgeDatabase } from "./db.js";
import type { EventBus } from "./eventBus.js";
import type { PluginHub } from "./pluginHub.js";

export type RouteDeps = {
  config: BridgeConfig;
  database: BridgeDatabase;
  events: EventBus;
  pluginHub: PluginHub;
};

const createConversationSchema = z.object({
  title: z.string().min(1).default("New Conversation"),
  purpose: z.string().optional().nullable(),
  kind: z.enum(["main", "specialist", "support", "system"]).default("specialist")
});

const patchConversationSchema = z.object({
  title: z.string().min(1).optional(),
  purpose: z.string().optional().nullable(),
  pinned: z.boolean().optional(),
  archived: z.boolean().optional()
});

const sendMessageSchema = z.object({
  text: z.string().min(1),
  senderId: z.string().min(1).default("ios:primary")
});

export function createApp(deps: RouteDeps): Hono {
  const app = new Hono();

  app.get("/healthz", (c) => c.json({ ok: true, service: "lobsterpot-bridge", now: nowIso() }));

  app.get("/api/status", (c) => c.json({
    ok: true,
    service: "lobsterpot-bridge",
    plugin: deps.pluginHub.status(),
    publicBaseUrl: deps.config.publicBaseUrl,
    now: nowIso()
  }));

  app.post("/api/setup/token", async (c) => {
    const body = await readJson(c.req.raw);
    const label = z.object({ label: z.string().optional() }).partial().parse(body).label;
    const token = deps.database.createBridgeToken(label);
    return c.json(token, 201);
  });

  app.get("/api/setup/snippet", (c) => {
    const baseUrl = normalizeBaseUrl(deps.config.publicBaseUrl);
    return c.json({
      json5: `{
  channels: {
    lobsterpot: {
      enabled: true,
      bridgeUrl: "${baseUrl}",
      token: "lobsterpot_...",
      dmPolicy: "allowlist",
      allowFrom: ["ios:primary"]
    }
  }
}`,
      bridgeUrl: baseUrl
    });
  });

  app.post("/api/devices/pair/start", (c) => c.json({
    pairingId: createId(),
    code: createPairingCode(),
    expiresAt: new Date(Date.now() + 10 * 60_000).toISOString()
  }, 201));

  app.post("/api/devices/pair/finish", (c) => c.json({
    deviceId: createId(),
    token: `device_${createId().replaceAll("-", "")}`,
    createdAt: nowIso()
  }, 201));

  app.get("/api/conversations", (c) => c.json({ conversations: deps.database.listConversations() }));

  app.post("/api/conversations", async (c) => {
    const body = createConversationSchema.parse(await readJson(c.req.raw));
    const conversation = deps.database.createConversation(body);
    deps.events.publish({ direction: "out", type: "conversation.created", conversationId: conversation.id, payload: conversation });
    return c.json({ conversation }, 201);
  });

  app.patch("/api/conversations/:id", async (c) => {
    const body = patchConversationSchema.parse(await readJson(c.req.raw));
    const conversation = deps.database.updateConversation(c.req.param("id"), body);
    if (!conversation) return c.json({ error: "conversation_not_found" }, 404);
    deps.events.publish({ direction: "out", type: "conversation.updated", conversationId: conversation.id, payload: conversation });
    return c.json({ conversation });
  });

  app.get("/api/conversations/:id/messages", (c) => {
    const conversation = deps.database.getConversation(c.req.param("id"));
    if (!conversation) return c.json({ error: "conversation_not_found" }, 404);
    return c.json({ messages: deps.database.listMessages(conversation.id) });
  });

  app.post("/api/conversations/:id/messages", async (c) => {
    const conversation = deps.database.getConversation(c.req.param("id"));
    if (!conversation) return c.json({ error: "conversation_not_found" }, 404);

    const body = sendMessageSchema.parse(await readJson(c.req.raw));
    const eventId = createId();
    const message = deps.database.createMessage({
      conversationId: conversation.id,
      role: "user",
      content: body.text,
      status: "sent",
      sourceEventId: eventId
    });

    const event = inboundMessageSchema.parse({
      type: "inbound.message",
      id: eventId,
      conversationId: conversation.id,
      senderId: body.senderId,
      text: body.text,
      createdAt: nowIso(),
      metadata: {
        conversationTitle: conversation.title,
        conversationPurpose: conversation.purpose,
        conversationKind: conversation.kind
      }
    });

    const accepted = deps.pluginHub.sendInboundMessage(event);
    deps.events.publish({ direction: "out", type: event.type, conversationId: conversation.id, payload: event });

    if (!accepted) {
      return c.json({ error: "openclaw_plugin_not_connected", message }, 503);
    }

    return c.json({ message, eventId }, 202);
  });

  app.post("/api/conversations/:id/actions", async (c) => {
    const conversation = deps.database.getConversation(c.req.param("id"));
    if (!conversation) return c.json({ error: "conversation_not_found" }, 404);
    const payload = await readJson(c.req.raw);
    deps.events.publish({ direction: "out", type: "inbound.action", conversationId: conversation.id, payload });
    return c.json({ accepted: deps.pluginHub.sendToPlugin(payload as never) }, 202);
  });

  app.get("/api/events", (c) => streamSSE(c, async (stream) => {
    const lastEventId = c.req.header("last-event-id") ?? c.req.query("cursor") ?? null;
    for (const event of deps.database.listEventsAfter(lastEventId)) {
      await stream.writeSSE({ id: event.cursor, event: event.type, data: JSON.stringify(event) });
    }

    const unsubscribe = deps.events.subscribe(async (event) => {
      await stream.writeSSE({ id: event.cursor, event: event.type, data: JSON.stringify(event) });
    });

    try {
      while (!stream.aborted) {
        await stream.sleep(25_000);
        await stream.writeSSE({ event: "ping", data: JSON.stringify({ now: nowIso() }) });
      }
    } finally {
      unsubscribe();
    }
  }));

  app.post("/api/push/register", async (c) => {
    const payload = await readJson(c.req.raw);
    deps.events.publish({ direction: "out", type: "push.registered", payload });
    return c.json({ ok: true, mode: "recorded-only" }, 202);
  });

  app.post("/api/push/test", (c) => c.json({ ok: true, mode: "not-configured" }, 202));

  app.get("/api/diagnostics", (c) => c.json({
    service: "lobsterpot-bridge",
    plugin: deps.pluginHub.status(),
    conversations: deps.database.listConversations().length,
    now: nowIso()
  }));

  return app;
}

async function readJson(request: Request): Promise<unknown> {
  const text = await request.text();
  if (!text.trim()) return {};
  return JSON.parse(text) as unknown;
}

function createPairingCode(): string {
  return Math.random().toString(36).slice(2, 10).toUpperCase();
}
