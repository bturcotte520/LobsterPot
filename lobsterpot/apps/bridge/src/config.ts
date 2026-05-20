import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";

export type BridgeConfig = {
  port: number;
  publicBaseUrl: string;
  dbPath: string;
};

export function loadConfig(env: NodeJS.ProcessEnv = process.env): BridgeConfig {
  const dbPath = resolve(env.LOBSTERPOT_DB_PATH ?? "./apps/bridge/data/lobsterpot.db");
  mkdirSync(dirname(dbPath), { recursive: true });

  return {
    port: Number(env.LOBSTERPOT_BRIDGE_PORT ?? 3000),
    publicBaseUrl: env.LOBSTERPOT_PUBLIC_BASE_URL ?? "http://127.0.0.1:3000",
    dbPath
  };
}
