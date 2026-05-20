import { serve } from "@hono/node-server";
import type { Server } from "node:http";
import { loadConfig } from "./config.js";
import { BridgeDatabase } from "./db.js";
import { EventBus } from "./eventBus.js";
import { PluginHub } from "./pluginHub.js";
import { createApp } from "./routes.js";

export function createBridgeRuntime() {
  const config = loadConfig();
  const database = new BridgeDatabase(config.dbPath);
  const events = new EventBus(database);
  const pluginHub = new PluginHub(database, events);
  const app = createApp({ config, database, events, pluginHub });
  return { app, config, database, events, pluginHub };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const runtime = createBridgeRuntime();
  const server = serve({ fetch: runtime.app.fetch, port: runtime.config.port }, (info) => {
    console.log(`LobsterPot bridge listening on http://127.0.0.1:${info.port}`);
  });
  runtime.pluginHub.attach(server as unknown as Server);
}
