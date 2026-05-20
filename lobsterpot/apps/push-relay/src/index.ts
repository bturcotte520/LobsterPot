import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { z } from "zod";
import { createId, createToken, nowIso, sha256 } from "@lobsterpot/shared";

const registerSchema = z.object({
  bundleId: z.string().min(1),
  deviceToken: z.string().min(1),
  bridgeId: z.string().min(1),
  environment: z.enum(["sandbox", "production"]).default("sandbox")
});

const sendSchema = z.object({
  handle: z.string().min(1),
  grant: z.string().min(1),
  title: z.string().min(1),
  body: z.string().min(1),
  conversationId: z.string().optional()
});

type Registration = {
  id: string;
  handle: string;
  grantHash: string;
  bridgeId: string;
  bundleId: string;
  environment: "sandbox" | "production";
  createdAt: string;
};

const registrations = new Map<string, Registration>();

export function createRelayApp(env: NodeJS.ProcessEnv = process.env): Hono {
  const adminToken = env.LOBSTERPOT_RELAY_ADMIN_TOKEN ?? "dev-relay-token";
  const app = new Hono();

  app.get("/healthz", (c) => c.json({ ok: true, service: "lobsterpot-push-relay", now: nowIso() }));

  app.post("/api/register", async (c) => {
    requireBearer(c.req.header("authorization"), adminToken);
    const input = registerSchema.parse(await readJson(c.req.raw));
    const id = createId();
    const handle = `relay_${id.replaceAll("-", "")}`;
    const grant = createToken("relaygrant");
    const registration: Registration = {
      id,
      handle,
      grantHash: sha256(grant),
      bridgeId: input.bridgeId,
      bundleId: input.bundleId,
      environment: input.environment,
      createdAt: nowIso()
    };
    registrations.set(handle, registration);
    return c.json({ handle, grant, createdAt: registration.createdAt }, 201);
  });

  app.post("/api/send", async (c) => {
    const input = sendSchema.parse(await readJson(c.req.raw));
    const registration = registrations.get(input.handle);
    if (!registration || registration.grantHash !== sha256(input.grant)) {
      return c.json({ error: "invalid_relay_grant" }, 401);
    }

    return c.json({
      ok: true,
      delivered: false,
      mode: "stub",
      reason: "APNs provider is not configured in this scaffold yet.",
      notification: {
        title: input.title,
        body: input.body,
        conversationId: input.conversationId ?? null
      }
    }, 202);
  });

  return app;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const port = Number(process.env.LOBSTERPOT_RELAY_PORT ?? 3100);
  serve({ fetch: createRelayApp().fetch, port }, (info) => {
    console.log(`LobsterPot push relay listening on http://127.0.0.1:${info.port}`);
  });
}

async function readJson(request: Request): Promise<unknown> {
  const text = await request.text();
  if (!text.trim()) return {};
  return JSON.parse(text) as unknown;
}

function requireBearer(header: string | undefined, expected: string): void {
  if (header !== `Bearer ${expected}`) {
    throw new Error("unauthorized");
  }
}
