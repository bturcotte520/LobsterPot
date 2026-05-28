import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { z } from "zod";
import { nowIso, sha256 } from "@lobsterpot/shared";
import { RelayDatabase } from "./db.js";
import { ApnsProvider } from "./apns.js";

// ── Schemas ───────────────────────────────────────────────────────────────────

const registerSchema = z.object({
  bundleId: z.string().min(1),
  bridgeId: z.string().min(1),
  apnsDeviceToken: z.string().optional(),
  environment: z.enum(["sandbox", "production"]).default("sandbox")
});

const updateTokenSchema = z.object({
  apnsDeviceToken: z.string().min(1)
});

const sendSchema = z.object({
  handle: z.string().min(1),
  grant: z.string().min(1),
  title: z.string().min(1),
  body: z.string().min(1),
  conversationId: z.string().optional(),
  badge: z.number().int().optional(),
  sound: z.string().optional().default("default")
});

// ── App factory ───────────────────────────────────────────────────────────────

export function createRelayApp(
  database: RelayDatabase,
  apns: ApnsProvider | null,
  env: NodeJS.ProcessEnv = process.env
): Hono {
  const adminToken = env.LOBSTERPOT_RELAY_ADMIN_TOKEN ?? "dev-relay-token";
  const app = new Hono();

  app.get("/healthz", (c) => c.json({
    ok: true,
    service: "lobsterpot-push-relay",
    apnsConfigured: apns !== null,
    now: nowIso()
  }));

  // ── Admin: register a bridge instance ────────────────────────────────────

  app.post("/api/register", async (c) => {
    if (!checkAdmin(c.req.header("authorization"), adminToken)) {
      return c.json({ error: "unauthorized" }, 401);
    }
    const input = registerSchema.parse(await readJson(c.req.raw));
    const reg = database.createRegistration(input);
    return c.json({ handle: reg.handle, grant: reg.grant, createdAt: reg.createdAt }, 201);
  });

  // ── Update the APNs device token for a registration ───────────────────────

  app.put("/api/registrations/:handle/token", async (c) => {
    const { handle } = c.req.param();
    const auth = c.req.header("authorization") ?? "";
    const grant = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    const reg = database.findByHandle(handle);
    if (!reg || reg.grantHash !== sha256(grant)) {
      return c.json({ error: "unauthorized" }, 401);
    }
    const { apnsDeviceToken } = updateTokenSchema.parse(await readJson(c.req.raw));
    database.updateApnsToken(handle, apnsDeviceToken);
    return c.json({ ok: true });
  });

  // ── Send a push notification ──────────────────────────────────────────────

  app.post("/api/send", async (c) => {
    const input = sendSchema.parse(await readJson(c.req.raw));
    const reg = database.findByHandle(input.handle);
    if (!reg || reg.grantHash !== sha256(input.grant)) {
      return c.json({ error: "invalid_relay_grant" }, 401);
    }

    if (!reg.apnsDeviceToken) {
      return c.json({ ok: false, delivered: false, reason: "no_apns_device_token" }, 202);
    }

    if (!apns) {
      return c.json({
        ok: true, delivered: false, mode: "stub",
        reason: "APNs not configured (set LOBSTERPOT_APNS_* env vars)"
      }, 202);
    }

    const result = await apns.send(reg.apnsDeviceToken, {
      alert: { title: input.title, body: input.body },
      sound: input.sound,
      badge: input.badge,
      "thread-id": input.conversationId
    }, {
      pushType: "alert",
      priority: 10
    });

    if (result.ok) {
      return c.json({ ok: true, delivered: true, apnsId: result.apnsId }, 200);
    } else {
      // BadDeviceToken means the token is stale — remove it
      if (result.reason === "BadDeviceToken" || result.reason === "Unregistered") {
        database.updateApnsToken(input.handle, "");
      }
      return c.json({ ok: false, delivered: false, status: result.status, reason: result.reason }, 502);
    }
  });

  // ── Remove a registration ─────────────────────────────────────────────────

  app.delete("/api/registrations/:handle", async (c) => {
    const { handle } = c.req.param();
    const auth = c.req.header("authorization") ?? "";
    const grant = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    const reg = database.findByHandle(handle);
    if (!reg || reg.grantHash !== sha256(grant)) {
      return c.json({ error: "unauthorized" }, 401);
    }
    database.deleteByHandle(handle);
    return c.json({ ok: true }, 200);
  });

  return app;
}

// ── Entry point ───────────────────────────────────────────────────────────────

if (import.meta.url === `file://${process.argv[1]}`) {
  const env = process.env;
  const port = Number(env.LOBSTERPOT_RELAY_PORT ?? 3100);
  const dbPath = resolve(env.LOBSTERPOT_RELAY_DB_PATH ?? "./apps/push-relay/data/relay.db");

  const database = new RelayDatabase(dbPath);
  const apns = buildApnsProvider(env);

  serve({ fetch: createRelayApp(database, apns, env).fetch, port }, (info) => {
    console.log(`LobsterPot push relay listening on http://127.0.0.1:${info.port}`);
    if (!apns) {
      console.warn("APNs not configured — set LOBSTERPOT_APNS_TEAM_ID, LOBSTERPOT_APNS_KEY_ID, LOBSTERPOT_APNS_BUNDLE_ID, LOBSTERPOT_APNS_PRIVATE_KEY_PATH");
    }
  });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

export function buildApnsProvider(env: NodeJS.ProcessEnv): ApnsProvider | null {
  const teamId = env.LOBSTERPOT_APNS_TEAM_ID;
  const keyId = env.LOBSTERPOT_APNS_KEY_ID;
  const bundleId = env.LOBSTERPOT_APNS_BUNDLE_ID;
  const keyPath = env.LOBSTERPOT_APNS_PRIVATE_KEY_PATH;

  if (!teamId || !keyId || !bundleId || !keyPath) return null;

  let privateKey: string;
  try {
    privateKey = readFileSync(resolve(keyPath), "utf8");
  } catch {
    console.error(`APNs key not found at ${keyPath}`);
    return null;
  }

  return new ApnsProvider({
    teamId,
    keyId,
    privateKey,
    bundleId,
    production: env.LOBSTERPOT_APNS_PRODUCTION === "true"
  });
}

async function readJson(request: Request): Promise<unknown> {
  const text = await request.text();
  if (!text.trim()) return {};
  return JSON.parse(text) as unknown;
}

function checkAdmin(header: string | undefined, expected: string): boolean {
  return header === `Bearer ${expected}`;
}
