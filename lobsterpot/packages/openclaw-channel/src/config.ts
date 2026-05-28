import { z } from "zod";

export const lobsterPotChannelConfigSchema = z.object({
  enabled: z.boolean().default(true),
  bridgeUrl: z.string().min(1),
  token: z.string().min(1),
  dmPolicy: z.enum(["allowlist", "pairing", "open", "disabled"]).default("allowlist"),
  allowFrom: z.array(z.string()).default(["ios:primary"]),
  streaming: z.object({ progress: z.boolean().default(true) }).default({ progress: true }),
  threadBindings: z.object({
    enabled: z.boolean().default(true),
    spawnSessions: z.boolean().default(true),
    idleHours: z.number().default(24),
    maxAgeHours: z.number().default(0),
    defaultSpawnContext: z.enum(["isolated", "fork"]).default("fork")
  }).default({})
});

export type LobsterPotChannelConfig = z.infer<typeof lobsterPotChannelConfigSchema>;

export type LobsterPotResolvedAccount = {
  accountId: string | null;
  bridgeUrl: string;
  token: string;
  dmPolicy: string;
  allowFrom: string[];
};

/**
 * Resolve the LobsterPot channel config from the raw OpenClaw config object.
 * Works in both full-runtime and setup-only paths.
 */
export function resolveLobsterPotAccount(
  cfg: Record<string, unknown>,
  accountId?: string | null
): LobsterPotResolvedAccount {
  const section = (cfg["channels"] as Record<string, unknown> | undefined)?.["lobsterpot"];
  const parsed = lobsterPotChannelConfigSchema.parse(section);
  return {
    accountId: accountId ?? null,
    bridgeUrl: parsed.bridgeUrl,
    token: parsed.token,
    dmPolicy: parsed.dmPolicy,
    allowFrom: parsed.allowFrom
  };
}

export function inspectLobsterPotAccount(
  cfg: Record<string, unknown>,
  _accountId?: string | null
): { enabled: boolean; configured: boolean; bridgeUrlStatus: string; tokenStatus: string } {
  const section = (cfg["channels"] as Record<string, unknown> | undefined)?.["lobsterpot"] as Record<string, unknown> | undefined;
  const bridgeUrl = typeof section?.["bridgeUrl"] === "string" ? section["bridgeUrl"] : null;
  const token = typeof section?.["token"] === "string" ? section["token"] : null;
  const enabled = section?.["enabled"] !== false;
  return {
    enabled: enabled && Boolean(bridgeUrl) && Boolean(token),
    configured: Boolean(bridgeUrl) && Boolean(token),
    bridgeUrlStatus: bridgeUrl ? "available" : "missing",
    tokenStatus: token ? "available" : "missing"
  };
}
