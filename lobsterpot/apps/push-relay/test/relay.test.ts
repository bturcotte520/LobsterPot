import { describe, expect, it } from "vitest";
import { mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { RelayDatabase } from "../src/db.js";
import { createRelayApp } from "../src/index.js";

function testApp() {
  const dir = mkdtempSync(join(tmpdir(), "lobsterpot-relay-"));
  const database = new RelayDatabase(join(dir, "relay.db"));
  const app = createRelayApp(database, null, { LOBSTERPOT_RELAY_ADMIN_TOKEN: "test-admin" });
  return { app, database };
}

describe("push relay", () => {
  it("healthz returns apns configured=false when not wired", async () => {
    const { app } = testApp();
    const res = await app.request("/healthz");
    const body = await res.json() as { ok: boolean; apnsConfigured: boolean };
    expect(res.status).toBe(200);
    expect(body.apnsConfigured).toBe(false);
  });

  it("register requires admin token", async () => {
    const { app } = testApp();
    const res = await app.request("/api/register", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ bundleId: "com.test", bridgeId: "b1" })
    });
    expect(res.status).toBe(401);
  });

  it("register creates a relay entry and returns handle + grant", async () => {
    const { app } = testApp();
    const res = await app.request("/api/register", {
      method: "POST",
      headers: {
        authorization: "Bearer test-admin",
        "Content-Type": "application/json"
      },
      body: JSON.stringify({ bundleId: "com.lobsterpot.app", bridgeId: "my-bridge" })
    });
    const body = await res.json() as { handle: string; grant: string };
    expect(res.status).toBe(201);
    expect(body.handle.startsWith("relay_")).toBe(true);
    expect(body.grant.startsWith("relaygrant_")).toBe(true);
  });

  it("send rejects invalid grant", async () => {
    const { app } = testApp();
    const res = await app.request("/api/send", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ handle: "relay_fake", grant: "badgrant", title: "Hi", body: "Test" })
    });
    expect(res.status).toBe(401);
  });

  it("send returns stub when apns not configured", async () => {
    const { app } = testApp();

    // Register
    const reg = await app.request("/api/register", {
      method: "POST",
      headers: { authorization: "Bearer test-admin", "Content-Type": "application/json" },
      body: JSON.stringify({ bundleId: "com.lobsterpot.app", bridgeId: "b1", apnsDeviceToken: "device-abc" })
    });
    const { handle, grant } = await reg.json() as { handle: string; grant: string };

    const res = await app.request("/api/send", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ handle, grant, title: "New message", body: "Hello" })
    });
    const body = await res.json() as { ok: boolean; delivered: boolean; mode: string };
    expect(res.status).toBe(202);
    expect(body.mode).toBe("stub");
  });

  it("delete removes a registration", async () => {
    const { app } = testApp();

    const reg = await app.request("/api/register", {
      method: "POST",
      headers: { authorization: "Bearer test-admin", "Content-Type": "application/json" },
      body: JSON.stringify({ bundleId: "com.lobsterpot.app", bridgeId: "b1" })
    });
    const { handle, grant } = await reg.json() as { handle: string; grant: string };

    const del = await app.request(`/api/registrations/${handle}`, {
      method: "DELETE",
      headers: { authorization: `Bearer ${grant}` }
    });
    expect(del.status).toBe(200);

    // Sending after deletion should fail with invalid grant
    const send = await app.request("/api/send", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ handle, grant, title: "X", body: "Y" })
    });
    expect(send.status).toBe(401);
  });

  it("update APNs device token", async () => {
    const { app, database } = testApp();

    const reg = await app.request("/api/register", {
      method: "POST",
      headers: { authorization: "Bearer test-admin", "Content-Type": "application/json" },
      body: JSON.stringify({ bundleId: "com.lobsterpot.app", bridgeId: "b1" })
    });
    const { handle, grant } = await reg.json() as { handle: string; grant: string };

    const update = await app.request(`/api/registrations/${handle}/token`, {
      method: "PUT",
      headers: { authorization: `Bearer ${grant}`, "Content-Type": "application/json" },
      body: JSON.stringify({ apnsDeviceToken: "new-device-token-abc" })
    });
    expect(update.status).toBe(200);

    const stored = database.findByHandle(handle);
    expect(stored?.apnsDeviceToken).toBe("new-device-token-abc");
  });
});
