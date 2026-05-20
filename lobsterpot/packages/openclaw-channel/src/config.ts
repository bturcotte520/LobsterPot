import { z } from "zod";
import { normalizeBaseUrl } from "@lobsterpot/shared";

export const lobsterPotChannelConfigSchema = z.object({
  enabled: z.boolean().default(true),
  bridgeUrl: z.string().min(1),
  token: z.string().startsWith("lobsterpot_"),
  dmPolicy: z.enum(["allowlist", "pairing", "open", "disabled"]).default("allowlist"),
  allowFrom: z.array(z.string()).default(["ios:primary"]),
  streaming: z.object({ progress: z.boolean().default(true) }).default({ progress: true })
});

export type LobsterPotChannelConfig = z.infer<typeof lobsterPotChannelConfigSchema>;

export function resolveLobsterPotConfig(raw: unknown): LobsterPotChannelConfig {
  const parsed = lobsterPotChannelConfigSchema.parse(raw);
  return { ...parsed, bridgeUrl: normalizeBaseUrl(parsed.bridgeUrl) };
}
