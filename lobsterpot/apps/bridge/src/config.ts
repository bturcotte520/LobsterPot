import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";

export type BridgeConfig = {
  port: number;
  publicBaseUrl: string;
  dbPath: string;
  /** Push relay base URL, e.g. "https://relay.example.com". Undefined = push disabled. */
  pushRelayUrl?: string;
  /** Admin token for authenticating bridge→relay API calls (POST /api/register). */
  pushRelayToken?: string;
  /** APNs bundle ID forwarded to the relay at registration time. */
  pushRelayBundleId?: string;
};

export function loadConfig(env: NodeJS.ProcessEnv = process.env): BridgeConfig {
  const dbPath = resolve(env.LOBSTERPOT_DB_PATH ?? "./apps/bridge/data/lobsterpot.db");
  mkdirSync(dirname(dbPath), { recursive: true });

  return {
    port: Number(env.LOBSTERPOT_BRIDGE_PORT ?? 3000),
    publicBaseUrl: env.LOBSTERPOT_PUBLIC_BASE_URL ?? "http://127.0.0.1:3000",
    dbPath,
    pushRelayUrl: env.LOBSTERPOT_PUSH_RELAY_URL || undefined,
    pushRelayToken: env.LOBSTERPOT_PUSH_RELAY_TOKEN || undefined,
    pushRelayBundleId: env.LOBSTERPOT_APNS_BUNDLE_ID || undefined
  };
}
