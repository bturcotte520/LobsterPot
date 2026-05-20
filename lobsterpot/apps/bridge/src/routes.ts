import { Hono } from "hono";
import type { MiddlewareHandler } from "hono";
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

// ── Validation schemas ────────────────────────────────────────────────────────

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

// ── Auth middleware ───────────────────────────────────────────────────────────

/**
 * Routes that require a valid device Bearer token.
 * Unauthenticated paths: /healthz, /api/status, /api/setup/*, /api/devices/pair/*, /
 */
function requireDeviceAuth(database: BridgeDatabase): MiddlewareHandler {
  return async (c, next) => {
    const auth = c.req.header("authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : null;
    if (!token) {
      return c.json({ error: "missing_token" }, 401);
    }
    const device = database.validateDeviceToken(token);
    if (!device) {
      return c.json({ error: "invalid_token" }, 401);
    }
    await next();
  };
}

// ── App factory ───────────────────────────────────────────────────────────────

export function createApp(deps: RouteDeps): Hono {
  const app = new Hono();

  // Public routes
  app.get("/healthz", (c) => c.json({ ok: true, service: "lobsterpot-bridge", now: nowIso() }));

  app.get("/api/status", (c) => c.json({
    ok: true,
    service: "lobsterpot-bridge",
    plugin: deps.pluginHub.status(),
    publicBaseUrl: deps.config.publicBaseUrl,
    now: nowIso()
  }));

  // Token generation (public — called during initial bridge setup before any devices exist)
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

  // Device pairing (public — no device token exists yet)
  app.post("/api/devices/pair/start", (c) => {
    const pairing = deps.database.createPairingCode();
    return c.json({ pairingId: pairing.id, code: pairing.code, expiresAt: pairing.expiresAt }, 201);
  });

  app.post("/api/devices/pair/finish", async (c) => {
    const body = await readJson(c.req.raw);
    const { code } = z.object({ code: z.string().min(1) }).parse(body);
    const pairingCode = deps.database.consumePairingCode(code);
    if (!pairingCode) {
      return c.json({ error: "invalid_or_expired_code" }, 400);
    }
    const device = deps.database.createDevice(pairingCode.id);
    deps.events.publish({ direction: "in", type: "device.paired", payload: { deviceId: device.id } });
    return c.json({ deviceId: device.id, token: device.token, createdAt: device.createdAt }, 201);
  });

  // ── Authenticated routes ──────────────────────────────────────────────────

  const auth = requireDeviceAuth(deps.database);

  app.get("/api/conversations", auth, (c) => c.json({ conversations: deps.database.listConversations() }));

  app.post("/api/conversations", auth, async (c) => {
    const body = createConversationSchema.parse(await readJson(c.req.raw));
    const conversation = deps.database.createConversation(body);
    deps.events.publish({ direction: "out", type: "conversation.created", conversationId: conversation.id, payload: conversation });
    return c.json({ conversation }, 201);
  });

  app.patch("/api/conversations/:id", auth, async (c) => {
    const body = patchConversationSchema.parse(await readJson(c.req.raw));
    const conversation = deps.database.updateConversation(c.req.param("id")!, body);
    if (!conversation) return c.json({ error: "conversation_not_found" }, 404);
    deps.events.publish({ direction: "out", type: "conversation.updated", conversationId: conversation.id, payload: conversation });
    return c.json({ conversation });
  });

  app.get("/api/conversations/:id/messages", auth, (c) => {
    const conversation = deps.database.getConversation(c.req.param("id")!);
    if (!conversation) return c.json({ error: "conversation_not_found" }, 404);
    return c.json({ messages: deps.database.listMessages(conversation.id) });
  });

  app.post("/api/conversations/:id/messages", auth, async (c) => {
    const conversation = deps.database.getConversation(c.req.param("id")!);
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

  app.post("/api/conversations/:id/actions", auth, async (c) => {
    const conversation = deps.database.getConversation(c.req.param("id")!);
    if (!conversation) return c.json({ error: "conversation_not_found" }, 404);
    const payload = await readJson(c.req.raw);
    deps.events.publish({ direction: "out", type: "inbound.action", conversationId: conversation.id, payload });
    return c.json({ accepted: deps.pluginHub.sendToPlugin(payload as never) }, 202);
  });

  app.get("/api/events", auth, (c) => streamSSE(c, async (stream) => {
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

  app.post("/api/push/register", auth, async (c) => {
    const payload = await readJson(c.req.raw);
    deps.events.publish({ direction: "out", type: "push.registered", payload });
    return c.json({ ok: true, mode: "recorded-only" }, 202);
  });

  app.post("/api/push/test", auth, (c) => c.json({ ok: true, mode: "not-configured" }, 202));

  app.get("/api/diagnostics", auth, (c) => c.json({
    service: "lobsterpot-bridge",
    plugin: deps.pluginHub.status(),
    conversations: deps.database.listConversations().length,
    now: nowIso()
  }));

  // ── Admin UI ─────────────────────────────────────────────────────────────

  app.get("/", (c) => c.redirect("/admin", 302));
  app.get("/admin", (c) => {
    const baseUrl = normalizeBaseUrl(deps.config.publicBaseUrl);
    return c.html(adminHtml(baseUrl, deps.pluginHub.status().connected));
  });

  return app;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

async function readJson(request: Request): Promise<unknown> {
  const text = await request.text();
  if (!text.trim()) return {};
  return JSON.parse(text) as unknown;
}

function adminHtml(bridgeUrl: string, pluginConnected: boolean): string {
  const dot = pluginConnected
    ? `<span class="dot green"></span> OpenClaw connected`
    : `<span class="dot red"></span> OpenClaw not connected`;

  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>LobsterPot Bridge</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: system-ui, sans-serif; background: #0d1117; color: #e6edf3; min-height: 100vh; padding: 2rem; }
    h1 { font-size: 1.5rem; font-weight: 700; margin-bottom: 0.25rem; }
    .subtitle { color: #8b949e; font-size: 0.875rem; margin-bottom: 2rem; }
    .card { background: #161b22; border: 1px solid #30363d; border-radius: 8px; padding: 1.5rem; margin-bottom: 1.5rem; }
    .card h2 { font-size: 1rem; font-weight: 600; margin-bottom: 1rem; }
    .dot { display: inline-block; width: 8px; height: 8px; border-radius: 50%; vertical-align: middle; margin-right: 6px; }
    .dot.green { background: #3fb950; }
    .dot.red { background: #f85149; }
    label { display: block; font-size: 0.8125rem; color: #8b949e; margin-bottom: 4px; }
    pre { background: #0d1117; border: 1px solid #30363d; border-radius: 6px; padding: 1rem; font-size: 0.8125rem; overflow-x: auto; white-space: pre-wrap; word-break: break-all; }
    button { background: #238636; color: #fff; border: none; border-radius: 6px; padding: 0.5rem 1rem; font-size: 0.875rem; cursor: pointer; }
    button:hover { background: #2ea043; }
    button:active { background: #1a7f37; }
    input[type=text] { width: 100%; background: #0d1117; border: 1px solid #30363d; border-radius: 6px; padding: 0.5rem 0.75rem; color: #e6edf3; font-size: 0.875rem; margin-bottom: 0.75rem; }
    .row { display: flex; gap: 0.75rem; align-items: flex-start; }
    .row > * { flex: 1; }
    .row button { flex: 0 0 auto; margin-top: 0; }
    #token-output { margin-top: 0.75rem; }
    #token-value { word-break: break-all; font-family: monospace; color: #58a6ff; }
    .badge { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 0.75rem; font-weight: 600; }
    .badge.green { background: #0d2a14; color: #3fb950; border: 1px solid #238636; }
    .badge.red { background: #2a0d0d; color: #f85149; border: 1px solid #7d1b19; }
  </style>
</head>
<body>
  <h1>🦞 LobsterPot Bridge</h1>
  <p class="subtitle">${bridgeUrl}</p>

  <div class="card">
    <h2>Status</h2>
    <p>${dot}</p>
  </div>

  <div class="card">
    <h2>Generate Bridge Token</h2>
    <p style="font-size:0.875rem;color:#8b949e;margin-bottom:1rem">
      Generate a token and paste it into your OpenClaw channel config as <code>channels.lobsterpot.token</code>.
    </p>
    <div class="row">
      <div>
        <label>Label (optional)</label>
        <input type="text" id="token-label" placeholder="e.g. my-openclaw" />
      </div>
      <button onclick="generateToken()">Generate</button>
    </div>
    <div id="token-output" style="display:none">
      <label>Token (shown once — copy it now)</label>
      <pre id="token-value"></pre>
    </div>
  </div>

  <div class="card">
    <h2>OpenClaw Config Snippet</h2>
    <p style="font-size:0.875rem;color:#8b949e;margin-bottom:1rem">
      Add this to your OpenClaw config file and replace the token placeholder.
    </p>
    <pre id="snippet">Loading…</pre>
  </div>

  <script>
    async function generateToken() {
      const label = document.getElementById('token-label').value.trim();
      const body = label ? JSON.stringify({ label }) : '{}';
      const res = await fetch('/api/setup/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body
      });
      const data = await res.json();
      document.getElementById('token-value').textContent = data.token;
      document.getElementById('token-output').style.display = 'block';
    }

    async function loadSnippet() {
      const res = await fetch('/api/setup/snippet');
      const data = await res.json();
      document.getElementById('snippet').textContent = data.json5;
    }

    loadSnippet();
  </script>
</body>
</html>`;
}
