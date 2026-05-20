import { serve } from "@hono/node-server";
import type { Server } from "node:http";
import { createId } from "@lobsterpot/shared";
import { loadConfig } from "./config.js";
import { BridgeDatabase } from "./db.js";
import { EventBus } from "./eventBus.js";
import { PluginHub } from "./pluginHub.js";
import { PushRelayClient } from "./pushRelay.js";
import { PushDispatcher } from "./pushDispatcher.js";
import { createApp } from "./routes.js";

export function createBridgeRuntime() {
  const config = loadConfig();
  const database = new BridgeDatabase(config.dbPath);
  const events = new EventBus(database);
  const pluginHub = new PluginHub(database, events);

  // Build push relay client + dispatcher when env vars are present
  let pushRelay: PushRelayClient | undefined;
  let pushDispatcher: PushDispatcher | undefined;

  if (config.pushRelayUrl && config.pushRelayToken && config.pushRelayBundleId) {
    pushRelay = new PushRelayClient(
      config.pushRelayUrl,
      config.pushRelayToken,
      config.pushRelayBundleId
    );
    pushDispatcher = new PushDispatcher(database, pushRelay, events);
  }

  const app = createApp({ config, database, events, pluginHub, pushRelay });
  return { app, config, database, events, pluginHub, pushRelay, pushDispatcher };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const runtime = createBridgeRuntime();

  // Auto-register with the relay on first start (idempotent via UNIQUE relay_handle)
  if (runtime.pushRelay) {
    const existing = runtime.database.getRelayRegistration();
    if (!existing) {
      const bridgeId = createId();
      runtime.pushRelay.register(bridgeId).then((reg) => {
        if (reg) {
          runtime.database.upsertRelayRegistration({
            url: runtime.config.pushRelayUrl!,
            handle: reg.handle,
            grant: reg.grant
          });
          console.log(`Push relay registered: handle=${reg.handle}`);
        } else {
          console.warn("Push relay registration failed — push notifications disabled until relay is reachable.");
        }
      });
    } else {
      console.log(`Push relay already registered: handle=${existing.relay_handle}`);
    }
  }

  const server = serve({ fetch: runtime.app.fetch, port: runtime.config.port }, (info) => {
    console.log(`LobsterPot bridge listening on http://127.0.0.1:${info.port}`);
    if (!runtime.pushRelay) {
      console.log("Push relay not configured (set LOBSTERPOT_PUSH_RELAY_URL, _TOKEN, and LOBSTERPOT_APNS_BUNDLE_ID).");
    }
  });
  runtime.pluginHub.attach(server as unknown as Server);
}
