import { describe, expect, it, beforeEach } from "vitest";
import { mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createHash, randomBytes } from "node:crypto";
import { BridgeDatabase } from "../src/db.js";
import { EventBus } from "../src/eventBus.js";
import { PluginHub } from "../src/pluginHub.js";
import { createApp } from "../src/routes.js";
import type { Hono } from "hono";

// ── Test harness ──────────────────────────────────────────────────────────────

type TestEnv = { app: Hono; database: BridgeDatabase };

function testApp(): TestEnv {
  const dir = mkdtempSync(join(tmpdir(), "lobsterpot-bridge-"));
  const database = new BridgeDatabase(join(dir, "test.db"));
  const events = new EventBus(database);
  const pluginHub = new PluginHub(database, events);
  const app = createApp({
    config: { port: 0, publicBaseUrl: "http://127.0.0.1:3000", dbPath: join(dir, "test.db") },
    database,
    events,
    pluginHub
  });
  return { app, database };
}

/** Generate a PKCE code_verifier + code_challenge pair */
function pkce(): { codeVerifier: string; codeChallenge: string } {
  const codeVerifier = randomBytes(32).toString("base64url");
  const codeChallenge = createHash("sha256").update(codeVerifier).digest("hex");
  return { codeVerifier, codeChallenge };
}

/** Create a device token via the PKCE pairing flow and return the bearer header value */
async function pairDevice(app: Hono): Promise<string> {
  const { codeVerifier, codeChallenge } = pkce();
  const start = await app.request("/api/devices/pair/start", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ codeChallenge })
  });
  const { code } = await start.json() as { pairingId: string; code: string };
  const finish = await app.request("/api/devices/pair/finish", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ code, codeVerifier })
  });
  const { token } = await finish.json() as { token: string };
  return `Bearer ${token}`;
}

// ── Setup token ───────────────────────────────────────────────────────────────

describe("setup", () => {
  it("creates bridge tokens", async () => {
    const { app } = testApp();
    const res = await app.request("/api/setup/token", { method: "POST" });
    const body = await res.json() as { token: string };
    expect(res.status).toBe(201);
    expect(body.token.startsWith("lobsterpot_")).toBe(true);
  });

  it("creates bridge tokens with a label", async () => {
    const { app } = testApp();
    const res = await app.request("/api/setup/token", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ label: "my-openclaw" })
    });
    expect(res.status).toBe(201);
  });

  it("returns a config snippet", async () => {
    const { app } = testApp();
    const res = await app.request("/api/setup/snippet");
    const body = await res.json() as { json5: string; bridgeUrl: string };
    expect(res.status).toBe(200);
    expect(body.json5).toContain("lobsterpot");
    expect(body.bridgeUrl).toBe("http://127.0.0.1:3000");
  });
});

// ── Pairing ───────────────────────────────────────────────────────────────────

describe("pairing", () => {
  it("starts a pairing session", async () => {
    const { app } = testApp();
    const { codeChallenge } = pkce();
    const res = await app.request("/api/devices/pair/start", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ codeChallenge })
    });
    const body = await res.json() as { pairingId: string; code: string; expiresAt: string };
    expect(res.status).toBe(201);
    expect(body.code).toMatch(/^[A-Z0-9]{8}$/);
    expect(body.expiresAt).toBeTruthy();
  });

  it("rejects /pair/start without a codeChallenge", async () => {
    const { app } = testApp();
    const res = await app.request("/api/devices/pair/start", { method: "POST" });
    expect(res.status).toBe(400);
  });

  it("completes pairing and returns a device token", async () => {
    const { app } = testApp();
    const { codeVerifier, codeChallenge } = pkce();
    const start = await app.request("/api/devices/pair/start", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ codeChallenge })
    });
    const { code } = await start.json() as { code: string };

    const finish = await app.request("/api/devices/pair/finish", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, codeVerifier })
    });
    const body = await finish.json() as { token: string; deviceId: string };
    expect(finish.status).toBe(201);
    expect(body.token.startsWith("device_")).toBe(true);
    expect(body.deviceId).toBeTruthy();
  });

  it("rejects a wrong codeVerifier (PKCE check)", async () => {
    const { app } = testApp();
    const { codeChallenge } = pkce();
    const start = await app.request("/api/devices/pair/start", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ codeChallenge })
    });
    const { code } = await start.json() as { code: string };

    const res = await app.request("/api/devices/pair/finish", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, codeVerifier: "wrong-verifier" })
    });
    expect(res.status).toBe(400);
    const body = await res.json() as { error: string };
    expect(body.error).toBe("invalid_or_expired_code");
  });

  it("rejects a replayed pairing code", async () => {
    const { app } = testApp();
    const { codeVerifier, codeChallenge } = pkce();
    const start = await app.request("/api/devices/pair/start", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ codeChallenge })
    });
    const { code } = await start.json() as { code: string };

    // First use — success
    await app.request("/api/devices/pair/finish", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, codeVerifier })
    });

    // Second use — should fail
    const replay = await app.request("/api/devices/pair/finish", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code, codeVerifier })
    });
    expect(replay.status).toBe(400);
    const body = await replay.json() as { error: string };
    expect(body.error).toBe("invalid_or_expired_code");
  });

  it("rejects an invalid pairing code", async () => {
    const { app } = testApp();
    const { codeVerifier } = pkce();
    const res = await app.request("/api/devices/pair/finish", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ code: "BADCODE1", codeVerifier })
    });
    expect(res.status).toBe(400);
  });
});

// ── Auth middleware ───────────────────────────────────────────────────────────

describe("auth middleware", () => {
  it("rejects unauthenticated requests to protected routes", async () => {
    const { app } = testApp();
    const routes = [
      ["GET", "/api/conversations"],
      ["POST", "/api/conversations"],
      ["GET", "/api/events"],
      ["GET", "/api/diagnostics"]
    ] as const;

    for (const [method, path] of routes) {
      const res = await app.request(path, { method });
      expect(res.status, `${method} ${path} should be 401`).toBe(401);
    }
  });

  it("accepts valid device token", async () => {
    const { app } = testApp();
    const auth = await pairDevice(app);
    const res = await app.request("/api/conversations", { headers: { authorization: auth } });
    expect(res.status).toBe(200);
  });

  it("rejects wrong bearer token", async () => {
    const { app } = testApp();
    const res = await app.request("/api/conversations", {
      headers: { authorization: "Bearer device_totallyfake" }
    });
    expect(res.status).toBe(401);
  });

  it("rejects malformed Authorization header", async () => {
    const { app } = testApp();
    const res = await app.request("/api/conversations", {
      headers: { authorization: "NotBearer token" }
    });
    expect(res.status).toBe(401);
  });

  it("public routes remain accessible without auth", async () => {
    const { app } = testApp();
    expect((await app.request("/healthz")).status).toBe(200);
    expect((await app.request("/api/status")).status).toBe(200);
    expect((await app.request("/api/setup/snippet")).status).toBe(200);
  });
});

// ── Conversations ─────────────────────────────────────────────────────────────

describe("conversations", () => {
  it("creates a conversation", async () => {
    const { app } = testApp();
    const auth = await pairDevice(app);
    const res = await app.request("/api/conversations", {
      method: "POST",
      headers: { authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ title: "Research", purpose: "Answer research questions" })
    });
    const body = await res.json() as { conversation: { title: string; kind: string } };
    expect(res.status).toBe(201);
    expect(body.conversation.title).toBe("Research");
    expect(body.conversation.kind).toBe("specialist");
  });

  it("lists conversations", async () => {
    const { app } = testApp();
    const auth = await pairDevice(app);
    await app.request("/api/conversations", {
      method: "POST",
      headers: { authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ title: "First" })
    });
    await app.request("/api/conversations", {
      method: "POST",
      headers: { authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ title: "Second" })
    });
    const res = await app.request("/api/conversations", { headers: { authorization: auth } });
    const body = await res.json() as { conversations: unknown[] };
    expect(body.conversations).toHaveLength(2);
  });

  it("patches a conversation title", async () => {
    const { app } = testApp();
    const auth = await pairDevice(app);
    const create = await app.request("/api/conversations", {
      method: "POST",
      headers: { authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ title: "Old Title" })
    });
    const { conversation } = await create.json() as { conversation: { id: string } };

    const patch = await app.request(`/api/conversations/${conversation.id}`, {
      method: "PATCH",
      headers: { authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ title: "New Title" })
    });
    const updated = await patch.json() as { conversation: { title: string } };
    expect(patch.status).toBe(200);
    expect(updated.conversation.title).toBe("New Title");
  });

  it("returns 404 for unknown conversation", async () => {
    const { app } = testApp();
    const auth = await pairDevice(app);
    const res = await app.request("/api/conversations/00000000-0000-0000-0000-000000000000/messages", {
      headers: { authorization: auth }
    });
    expect(res.status).toBe(404);
  });
});

// ── Messages ──────────────────────────────────────────────────────────────────

describe("messages", () => {
  it("returns 503 when plugin not connected", async () => {
    const { app } = testApp();
    const auth = await pairDevice(app);
    const create = await app.request("/api/conversations", {
      method: "POST",
      headers: { authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ title: "Test conv" })
    });
    const { conversation } = await create.json() as { conversation: { id: string } };

    const res = await app.request(`/api/conversations/${conversation.id}/messages`, {
      method: "POST",
      headers: { authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ text: "Hello" })
    });
    expect(res.status).toBe(503);
    const body = await res.json() as { error: string };
    expect(body.error).toBe("openclaw_plugin_not_connected");
  });

  it("lists messages for a conversation", async () => {
    const { app, database } = testApp();
    const auth = await pairDevice(app);
    const create = await app.request("/api/conversations", {
      method: "POST",
      headers: { authorization: auth, "Content-Type": "application/json" },
      body: JSON.stringify({ title: "Test conv" })
    });
    const { conversation } = await create.json() as { conversation: { id: string } };

    // Seed a message directly in DB
    database.createMessage({
      conversationId: conversation.id,
      role: "assistant",
      content: "Hello there",
      status: "final"
    });

    const res = await app.request(`/api/conversations/${conversation.id}/messages`, {
      headers: { authorization: auth }
    });
    const body = await res.json() as { messages: Array<{ content: string }> };
    expect(res.status).toBe(200);
    expect(body.messages[0].content).toBe("Hello there");
  });
});

// ── SSE events ────────────────────────────────────────────────────────────────

describe("events cursor", () => {
  it("listEventsAfter returns events after the given cursor", async () => {
    const dir = mkdtempSync(join(tmpdir(), "lobsterpot-cursor-"));
    const database = new BridgeDatabase(join(dir, "test.db"));
    const events = new EventBus(database);

    const e1 = events.publish({ direction: "out", type: "test.event", payload: { n: 1 } });
    const e2 = events.publish({ direction: "out", type: "test.event", payload: { n: 2 } });
    const e3 = events.publish({ direction: "out", type: "test.event", payload: { n: 3 } });

    // Events after e1 should be e2 and e3 (cursor is exclusive lower bound)
    const afterE1 = database.listEventsAfter(e1.cursor);
    expect(afterE1).toHaveLength(2);
    const ids = afterE1.map((e) => e.id);
    expect(ids).toContain(e2.id);
    expect(ids).toContain(e3.id);
  });

  it("listEventsAfter with null returns recent events", async () => {
    const dir = mkdtempSync(join(tmpdir(), "lobsterpot-cursor2-"));
    const database = new BridgeDatabase(join(dir, "test.db"));
    const events = new EventBus(database);

    events.publish({ direction: "out", type: "test.a", payload: {} });
    events.publish({ direction: "out", type: "test.b", payload: {} });

    const all = database.listEventsAfter(null);
    expect(all.length).toBe(2);
  });
});

// ── Admin UI ──────────────────────────────────────────────────────────────────

describe("admin UI", () => {
  it("redirects / to /admin", async () => {
    const { app } = testApp();
    const res = await app.request("/", { redirect: "manual" } as RequestInit);
    expect(res.status).toBe(302);
  });

  it("serves admin HTML at /admin", async () => {
    const { app } = testApp();
    const res = await app.request("/admin");
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text).toContain("LobsterPot");
    expect(text).toContain("Generate Bridge Token");
  });
});

// ── Healthz + status ──────────────────────────────────────────────────────────

describe("public endpoints", () => {
  it("healthz returns ok", async () => {
    const { app } = testApp();
    const res = await app.request("/healthz");
    const body = await res.json() as { ok: boolean };
    expect(body.ok).toBe(true);
  });

  it("status includes plugin info", async () => {
    const { app } = testApp();
    const res = await app.request("/api/status");
    const body = await res.json() as { plugin: { connected: boolean } };
    expect(body.plugin.connected).toBe(false);
  });
});
