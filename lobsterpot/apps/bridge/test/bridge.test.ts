import { describe, expect, it } from "vitest";
import { mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { BridgeDatabase } from "../src/db.js";
import { EventBus } from "../src/eventBus.js";
import { PluginHub } from "../src/pluginHub.js";
import { createApp } from "../src/routes.js";

function testApp() {
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

describe("bridge routes", () => {
  it("creates setup tokens", async () => {
    const { app } = testApp();
    const response = await app.request("/api/setup/token", { method: "POST" });
    const body = await response.json() as { token: string };
    expect(response.status).toBe(201);
    expect(body.token.startsWith("lobsterpot_")).toBe(true);
  });

  it("creates conversations", async () => {
    const { app } = testApp();
    const response = await app.request("/api/conversations", {
      method: "POST",
      body: JSON.stringify({ title: "Research", purpose: "Answer research questions" })
    });
    const body = await response.json() as { conversation: { title: string } };
    expect(response.status).toBe(201);
    expect(body.conversation.title).toBe("Research");
  });
});
