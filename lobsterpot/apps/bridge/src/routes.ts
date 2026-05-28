import { Hono } from "hono";
import type { MiddlewareHandler } from "hono";
import { streamSSE } from "hono/streaming";
import { z, ZodError } from "zod";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { inboundMessageSchema } from "@lobsterpot/protocol";
import { createId, nowIso, normalizeBaseUrl } from "@lobsterpot/shared";
import type { BridgeConfig } from "./config.js";
import type { BridgeDatabase } from "./db.js";
import type { EventBus } from "./eventBus.js";
import type { PluginHub } from "./pluginHub.js";

// ── Rate limiter ──────────────────────────────────────────────────────────────

class RateLimiter {
  private readonly counts = new Map<string, { count: number; resetAt: number }>();

  constructor(
    private readonly max: number,
    private readonly windowMs: number
  ) {}

  check(key: string): boolean {
    const now = Date.now();
    const entry = this.counts.get(key);
    if (!entry || now >= entry.resetAt) {
      this.counts.set(key, { count: 1, resetAt: now + this.windowMs });
      return true;
    }
    if (entry.count >= this.max) return false;
    entry.count++;
    return true;
  }

  prune(): void {
    const now = Date.now();
    for (const [key, entry] of this.counts) {
      if (now >= entry.resetAt) this.counts.delete(key);
    }
  }
}

function clientIp(req: Request): string {
  return (
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    req.headers.get("x-real-ip") ??
    "unknown"
  );
}

function rateLimitMiddleware(limiter: RateLimiter): MiddlewareHandler {
  return async (c, next) => {
    if (!limiter.check(clientIp(c.req.raw))) {
      return c.json({ error: "rate_limited" }, 429);
    }
    await next();
  };
}

export type RouteDeps = {
  config: BridgeConfig;
  database: BridgeDatabase;
  events: EventBus;
  pluginHub: PluginHub;
  pushRelay?: import("./pushRelay.js").PushRelayClient;
};

// ── Validation schemas ────────────────────────────────────────────────────────

const createConversationSchema = z.object({
  title: z.string().min(1).default("New Conversation"),
  purpose: z.string().optional().nullable(),
  kind: z.enum(["main", "subagent", "specialist", "support", "system"]).default("specialist"),
  openclawSessionKey: z.string().min(1).optional().nullable(),
  openclawAgentId: z.string().min(1).optional().nullable()
});

const patchConversationSchema = z.object({
  title: z.string().min(1).optional(),
  purpose: z.string().optional().nullable(),
  pinned: z.boolean().optional(),
  archived: z.boolean().optional()
});

const sendMessageSchema = z.object({
  text: z.string().default(""),
  attachmentIds: z.array(z.string().uuid()).default([]),
  senderId: z.string().min(1).default("ios:primary")
}).refine((body) => body.text.trim().length > 0 || body.attachmentIds.length > 0, {
  message: "text_or_attachment_required"
});

// ── Plugin auth (bridge token) ────────────────────────────────────────────────

function requirePluginAuth(database: BridgeDatabase): MiddlewareHandler {
  return async (c, next) => {
    const auth = c.req.header("authorization") ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : null;
    if (!token) return c.json({ error: "missing_token" }, 401);
    const row = database.validateBridgeToken(token);
    if (!row) return c.json({ error: "invalid_token" }, 401);
    await next();
  };
}

// ── Auth middleware ───────────────────────────────────────────────────────────

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
    c.set("deviceId" as never, device.id as never);
    await next();
  };
}

// ── App factory ───────────────────────────────────────────────────────────────

export function createApp(deps: RouteDeps): Hono {
  const app = new Hono();

  app.onError((err, c) => {
    if (err instanceof ZodError) {
      return c.json({ error: "invalid_request", issues: err.issues }, 400);
    }
    throw err;
  });

  const pairStartLimiter = new RateLimiter(10, 5 * 60_000);
  const pairFinishLimiter = new RateLimiter(20, 5 * 60_000);
  const setupTokenLimiter = new RateLimiter(5, 60 * 60_000);

  setInterval(() => {
    pairStartLimiter.prune();
    pairFinishLimiter.prune();
    setupTokenLimiter.prune();
  }, 10 * 60_000).unref();

  // ── Public routes ──────────────────────────────────────────────────────────

  app.get("/healthz", (c) => c.json({
    ok: true,
    service: "lobsterpot-bridge",
    now: nowIso()
  }));

  app.get("/api/status", (c) => c.json({
    ok: true,
    service: "lobsterpot-bridge",
    plugin: deps.pluginHub.status(),
    publicBaseUrl: deps.config.publicBaseUrl,
    now: nowIso()
  }));

  app.post("/api/setup/token", rateLimitMiddleware(setupTokenLimiter), async (c) => {
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

  app.post(
    "/api/devices/pair/start",
    rateLimitMiddleware(pairStartLimiter),
    async (c) => {
      const body = await readJson(c.req.raw);
      const { codeChallenge } = z.object({
        codeChallenge: z.string().min(64).max(128)
      }).parse(body);
      const pairing = deps.database.createPairingCode(codeChallenge);
      return c.json({ pairingId: pairing.id, code: pairing.code, expiresAt: pairing.expiresAt }, 201);
    }
  );

  app.post(
    "/api/devices/pair/finish",
    rateLimitMiddleware(pairFinishLimiter),
    async (c) => {
      const body = await readJson(c.req.raw);
      const { code, codeVerifier } = z.object({
        code: z.string().min(1),
        codeVerifier: z.string().min(1)
      }).parse(body);
      const pairingCode = deps.database.consumePairingCode(code, codeVerifier);
      if (!pairingCode) {
        return c.json({ error: "invalid_or_expired_code" }, 400);
      }
      const device = deps.database.createDevice(pairingCode.id);
      deps.events.publish({
        direction: "in",
        type: "device.paired",
        payload: { deviceId: device.id }
      });
      return c.json({ deviceId: device.id, token: device.token, createdAt: device.createdAt }, 201);
    }
  );

  // ── Authenticated routes ───────────────────────────────────────────────────

  const auth = requireDeviceAuth(deps.database);

  app.get("/api/conversations", auth, (c) => {
    const archived = c.req.query("archived") === "true";
    return c.json({ conversations: deps.database.listConversations({ archived }) });
  });

  app.get("/api/search", auth, (c) => {
    const query = (c.req.query("q") ?? "").trim();
    if (!query) return c.json({ conversations: [], messages: [] });
    const includeArchived = c.req.query("includeArchived") === "true";
    return c.json(deps.database.search({ query, includeArchived }));
  });

  app.post("/api/conversations", auth, async (c) => {
    const body = createConversationSchema.parse(await readJson(c.req.raw));
    const conversation = deps.database.createConversation(body);
    deps.events.publish({
      direction: "out",
      type: "conversation.created",
      conversationId: conversation.id,
      payload: conversation
    });
    return c.json({ conversation }, 201);
  });

  app.patch("/api/conversations/:id", auth, async (c) => {
    const body = patchConversationSchema.parse(await readJson(c.req.raw));
    const conversation = deps.database.updateConversation(c.req.param("id")!, body);
    if (!conversation) return c.json({ error: "conversation_not_found" }, 404);
    deps.events.publish({
      direction: "out",
      type: "conversation.updated",
      conversationId: conversation.id,
      payload: conversation
    });
    return c.json({ conversation });
  });

  app.delete("/api/conversations/:id", auth, (c) => {
    const deleted = deps.database.deleteConversation(c.req.param("id")!);
    if (!deleted) return c.json({ error: "conversation_not_found_or_protected" }, 404);
    deps.events.publish({
      direction: "out",
      type: "conversation.deleted",
      conversationId: c.req.param("id")!,
      payload: { id: c.req.param("id")! }
    });
    return c.json({ ok: true });
  });

  app.get("/api/conversations/:id/messages", auth, (c) => {
    const conversation = deps.database.getConversation(c.req.param("id")!);
    if (!conversation) return c.json({ error: "conversation_not_found" }, 404);
    return c.json({ messages: deps.database.listMessages(conversation.id) });
  });

  app.post("/api/attachments", auth, async (c) => {
    const form = await c.req.raw.formData();
    const file = form.get("file");
    if (!(file instanceof File)) return c.json({ error: "missing_file" }, 400);
    const bytes = Buffer.from(await file.arrayBuffer());
    const safeName = basename(file.name || "attachment").replace(/[^A-Za-z0-9._ -]/g, "_");
    const attachmentDir = join(dirname(deps.config.dbPath), "attachments");
    await mkdir(attachmentDir, { recursive: true });
    const storagePath = join(attachmentDir, `${createId()}-${safeName}`);
    await writeFile(storagePath, bytes);
    const attachment = deps.database.createAttachment({
      filename: safeName,
      contentType: file.type || "application/octet-stream",
      byteSize: bytes.byteLength,
      storagePath
    });
    return c.json({ attachment }, 201);
  });

  app.get("/api/attachments/:id", auth, async (c) => {
    const attachment = deps.database.getAttachment(c.req.param("id")!);
    if (!attachment) return c.json({ error: "attachment_not_found" }, 404);
    const bytes = await readFile(attachment.storagePath);
    return c.body(bytes, 200, {
      "Content-Type": attachment.contentType,
      "Content-Disposition": `attachment; filename="${attachment.filename.replace(/"/g, "\\\"")}"`
    });
  });

  app.post("/api/conversations/:id/messages", auth, async (c) => {
    const conversation = deps.database.getConversation(c.req.param("id")!);
    if (!conversation) return c.json({ error: "conversation_not_found" }, 404);

    const body = sendMessageSchema.parse(await readJson(c.req.raw));
    const attachments = deps.database.getAttachments(body.attachmentIds);
    if (attachments.length !== body.attachmentIds.length) {
      return c.json({ error: "attachment_not_found" }, 400);
    }
    const attachmentRefs = attachments.map((attachment) => ({
      ...attachment,
      url: attachment.url ? `${normalizeBaseUrl(deps.config.publicBaseUrl)}${attachment.url}` : attachment.url
    }));
    const eventId = createId();
    const content = body.text.trim();
    const message = deps.database.createMessage({
      conversationId: conversation.id,
      role: "user",
      content,
      status: "sent",
      sourceEventId: eventId,
      attachmentIds: body.attachmentIds
    });

    const agentText = buildInboundText(content, attachmentRefs);

    const event = inboundMessageSchema.parse({
      type: "inbound.message",
      id: eventId,
      conversationId: conversation.id,
      senderId: body.senderId,
      text: agentText,
      createdAt: nowIso(),
      metadata: {
        conversationTitle: conversation.title,
        conversationPurpose: conversation.purpose,
        conversationKind: conversation.kind,
        openclawSessionKey: conversation.openclawSessionKey,
        openclawAgentId: conversation.openclawAgentId,
        attachments: attachmentRefs
      }
    });

    const accepted = deps.pluginHub.sendInboundMessage(event);
    deps.events.publish({
      direction: "out",
      type: event.type,
      conversationId: conversation.id,
      payload: event
    });

    if (!accepted) {
      return c.json({ error: "openclaw_plugin_not_connected", message }, 503);
    }

    return c.json({ message, eventId }, 202);
  });

  app.post("/api/conversations/:id/actions", auth, async (c) => {
    const conversation = deps.database.getConversation(c.req.param("id")!);
    if (!conversation) return c.json({ error: "conversation_not_found" }, 404);
    const payload = await readJson(c.req.raw);
    deps.events.publish({
      direction: "out",
      type: "inbound.action",
      conversationId: conversation.id,
      payload
    });
    return c.json({ accepted: deps.pluginHub.sendToPlugin(payload as never) }, 202);
  });

  // Plugin (bridge-token) routes — the OpenClaw plugin uses these to drive
  // bridge state from the OpenClaw side (e.g. auto-create subagent threads).
  const pluginAuth = requirePluginAuth(deps.database);

  app.post("/api/plugin/conversations", pluginAuth, async (c) => {
    const body = createConversationSchema.parse(await readJson(c.req.raw));
    const conversation = deps.database.createConversation(body);
    deps.events.publish({
      direction: "out",
      type: "conversation.created",
      conversationId: conversation.id,
      payload: conversation
    });
    return c.json({ conversation }, 201);
  });

  app.get("/api/events", auth, (c) => streamSSE(c, async (stream) => {
    const lastEventId =
      c.req.header("last-event-id") ?? c.req.query("cursor") ?? null;
    for (const event of deps.database.listEventsAfter(lastEventId)) {
      await stream.writeSSE({
        id: event.cursor,
        event: event.type,
        data: JSON.stringify(event)
      });
    }

    const unsubscribe = deps.events.subscribe(async (event) => {
      await stream.writeSSE({
        id: event.cursor,
        event: event.type,
        data: JSON.stringify(event)
      });
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
    const deviceId = c.get("deviceId" as never) as string;
    const body = await readJson(c.req.raw);
    const { apnsToken, environment } = z.object({
      apnsToken: z.string().min(1),
      environment: z.enum(["sandbox", "production"]).default("sandbox")
    }).parse(body);

    deps.database.updateDeviceApnsToken(deviceId, apnsToken, environment);

    if (deps.pushRelay) {
      const reg = deps.database.getRelayRegistration();
      if (reg) {
        void deps.pushRelay.updateToken(reg.relay_handle, reg.relay_grant, apnsToken);
      }
    }

    deps.events.publish({
      direction: "out",
      type: "push.registered",
      payload: { deviceId, environment }
    });
    return c.json({ ok: true, relayConfigured: !!deps.pushRelay }, 202);
  });

  app.post("/api/push/test", auth, async (c) => {
    const deviceId = c.get("deviceId" as never) as string;
    if (!deps.pushRelay) {
      return c.json({ ok: false, reason: "push_relay_not_configured" }, 202);
    }
    const reg = deps.database.getRelayRegistration();
    if (!reg) {
      return c.json({ ok: false, reason: "bridge_not_registered_with_relay" }, 202);
    }
    const device = deps.database.getDeviceById(deviceId);
    if (!device?.apns_token) {
      return c.json({ ok: false, reason: "no_apns_token_for_device" }, 202);
    }
    const sent = await deps.pushRelay.send(reg.relay_handle, reg.relay_grant, {
      title: "LobsterPot",
      body: "Push notifications are working!"
    });
    return c.json({ ok: sent }, 202);
  });

  app.get("/api/diagnostics", auth, (c) => c.json({
    service: "lobsterpot-bridge",
    plugin: deps.pluginHub.status(),
    conversations: deps.database.listConversations().length,
    now: nowIso()
  }));

  // ── Admin UI ───────────────────────────────────────────────────────────────

  app.get("/", (c) => c.redirect("/admin", 302));
  app.get("/admin", (c) => {
    const baseUrl = normalizeBaseUrl(deps.config.publicBaseUrl);
    return c.html(adminHtml(baseUrl, deps.pluginHub.status().connected));
  });

  return app;
}

// ── Helpers ────────────────────────────────────────────────────────────────────

async function readJson(request: Request): Promise<unknown> {
  const text = await request.text();
  if (!text.trim()) return {};
  return JSON.parse(text) as unknown;
}

function buildInboundText(text: string, attachments: Array<{ filename: string; contentType: string; byteSize: number; url?: string | null }>): string {
  if (attachments.length === 0) return text;
  const lines = attachments.map((attachment, index) =>
    `${index + 1}. ${attachment.filename} (${attachment.contentType}, ${attachment.byteSize} bytes)${attachment.url ? ` - ${attachment.url}` : ""}`
  );
  return [
    text,
    "",
    "[LobsterPot attachments]",
    ...lines
  ].filter((line, index) => index !== 0 || line.trim().length > 0).join("\n");
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
    input[type=text] { width: 100%; background: #0d1117; border: 1px solid #30363d; border-radius: 6px; padding: 0.5rem 0.75rem; color: #e6edf3; font-size: 0.875rem; margin-bottom: 0.75rem; }
    .row { display: flex; gap: 0.75rem; align-items: flex-start; }
    .row > * { flex: 1; }
    .row button { flex: 0 0 auto; margin-top: 0; }
    #token-output { margin-top: 0.75rem; }
    #token-value { word-break: break-all; font-family: monospace; color: #58a6ff; }
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
      Add this to your OpenClaw config and replace the token placeholder.
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
