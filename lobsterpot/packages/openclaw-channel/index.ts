import { defineChannelPluginEntry, type ChannelPlugin } from "openclaw/plugin-sdk/channel-core";
import { lobsterPotPlugin } from "./src/channel.js";
import { materializeOpenClawSubagentSession, startLobsterPotRuntime } from "./src/runtime.js";
import type { LobsterPotResolvedAccount } from "./src/channel.js";

// Explicit type annotation avoids TS2742 (internal path reference in inferred type)
const entry: ReturnType<typeof defineChannelPluginEntry<ChannelPlugin<LobsterPotResolvedAccount>>> = defineChannelPluginEntry({
  id: "lobsterpot",
  name: "LobsterPot",
  description: "Connect OpenClaw to the LobsterPot iOS app via the LobsterPot bridge.",
  plugin: lobsterPotPlugin,

  registerCliMetadata(api) {
    api.registerCli(
      ({ program }) => {
        program
          .command("lobsterpot")
          .description("LobsterPot iOS bridge management");
      },
      {
        descriptors: [
          {
            name: "lobsterpot",
            description: "LobsterPot iOS bridge management",
            hasSubcommands: false
          }
        ]
      }
    );
  },

  registerFull(api) {
    const runtime = startLobsterPotRuntime(api);
    api.registerHook?.("subagent_spawned", async (event: unknown) => {
      const spawned = event as {
        childSessionKey?: string;
        agentId?: string;
        label?: string;
        runId?: string;
        mode?: "run" | "session";
        requester?: { channel?: string; to?: string | number };
      };
      if (!spawned.childSessionKey || !spawned.agentId) return;
      const requesterConversationId =
        spawned.requester?.channel === "lobsterpot" && typeof spawned.requester.to === "string"
          ? spawned.requester.to
          : null;
      await materializeOpenClawSubagentSession({
        childSessionKey: spawned.childSessionKey,
        agentId: spawned.agentId,
        label: spawned.label,
        runId: spawned.runId,
        mode: spawned.mode,
        requesterConversationId
      });
    });
    void runtime;
  }
});

export default entry;
export { lobsterPotPlugin } from "./src/channel.js";
export { LobsterPotBridgeClient } from "./src/bridge-client.js";
export { resolveLobsterPotAccount, inspectLobsterPotAccount } from "./src/config.js";
