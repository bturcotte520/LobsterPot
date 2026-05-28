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

    type SubagentEvent = {
      childSessionKey?: string;
      agentId?: string;
      label?: string;
      runId?: string;
      mode?: "run" | "session";
      requester?: { channel?: string; accountId?: string; to?: string | number; threadId?: string | number };
    };

    const prepareSubagentThread = async (event: SubagentEvent): Promise<string | null> => {
      if (!event.childSessionKey || !event.agentId) return null;
      const requesterConversationId =
        event.requester?.channel === "lobsterpot" && typeof event.requester.to === "string"
          ? event.requester.to
          : null;
      return await materializeOpenClawSubagentSession({
        childSessionKey: event.childSessionKey,
        agentId: event.agentId,
        label: event.label,
        runId: event.runId,
        mode: event.mode,
        requesterConversationId
      });
    };

    api.on("subagent_spawning", async (event) => {
      const conversationId = await prepareSubagentThread(event as SubagentEvent);
      if (!conversationId) {
        return { status: "error", error: "Unable to create LobsterPot subagent thread." };
      }
      return {
        status: "ok",
        threadBindingReady: true,
        deliveryOrigin: {
          channel: "lobsterpot",
          accountId: (event as SubagentEvent).requester?.accountId,
          to: conversationId
        }
      };
    });

    api.on("subagent_spawned", async (event) => {
      await prepareSubagentThread(event as SubagentEvent);
    });
    void runtime;
  }
});

export default entry;
export { lobsterPotPlugin } from "./src/channel.js";
export { LobsterPotBridgeClient } from "./src/bridge-client.js";
export { resolveLobsterPotAccount, inspectLobsterPotAccount } from "./src/config.js";
