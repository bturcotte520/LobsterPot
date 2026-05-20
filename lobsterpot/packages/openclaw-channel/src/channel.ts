import { createId } from "@lobsterpot/shared";
import { LobsterPotBridgeClient } from "./bridge-client.js";
import { resolveLobsterPotConfig, type LobsterPotChannelConfig } from "./config.js";

export type LobsterPotRuntimeHooks = {
  onInboundMessage?: (input: {
    conversationId: string;
    senderId: string;
    text: string;
    metadata: Record<string, unknown>;
  }) => Promise<void> | void;
  log?: (message: string, details?: unknown) => void;
};

export type LobsterPotRuntime = {
  id: string;
  config: LobsterPotChannelConfig;
  client: LobsterPotBridgeClient;
  stop: () => void;
};

export function createLobsterPotRuntime(rawConfig: unknown, hooks: LobsterPotRuntimeHooks = {}): LobsterPotRuntime {
  const config = resolveLobsterPotConfig(rawConfig);
  const id = createId();
  const client = new LobsterPotBridgeClient(config, id, {
    connected: () => hooks.log?.("lobsterpot connected"),
    disconnected: () => hooks.log?.("lobsterpot disconnected"),
    error: (error) => hooks.log?.("lobsterpot error", { message: error.message }),
    inboundMessage: async (event) => {
      await hooks.onInboundMessage?.({
        conversationId: event.conversationId,
        senderId: event.senderId,
        text: event.text,
        metadata: event.metadata
      });
    }
  });
  client.start();
  return { id, config, client, stop: () => client.stop() };
}

export const lobsterPotChannelPlugin = {
  id: "lobsterpot",
  label: "LobsterPot",
  createRuntime: createLobsterPotRuntime
};
