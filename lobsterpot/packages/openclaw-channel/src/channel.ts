/**
 * LobsterPot OpenClaw channel plugin.
 *
 * Built against openclaw/plugin-sdk/channel-core (openclaw@2026.5.x).
 */

import {
  createChatChannelPlugin,
  type OpenClawConfig
} from "openclaw/plugin-sdk/channel-core";
import { DEFAULT_ACCOUNT_ID } from "openclaw/plugin-sdk/account-id";
import type { ChannelPlugin } from "openclaw/plugin-sdk/channel-core";
import { inspectLobsterPotAccount, resolveLobsterPotAccount, type LobsterPotResolvedAccount } from "./config.js";
import { sendOutboundText } from "./runtime.js";

export { inspectLobsterPotAccount, resolveLobsterPotAccount };
export type { LobsterPotResolvedAccount };

/**
 * Build the LobsterPot ChannelPlugin.
 *
 * The outbound sendText adapter is replaced at runtime by the entry point
 * once the bridge WebSocket client is live. Until then sendText is a no-op.
 */
export function buildLobsterPotPlugin(): ChannelPlugin<LobsterPotResolvedAccount> {
  return createChatChannelPlugin<LobsterPotResolvedAccount>({
    base: {
      id: "lobsterpot",

      meta: {
        id: "lobsterpot",
        label: "LobsterPot",
        selectionLabel: "LobsterPot iOS",
        docsPath: "channels/lobsterpot",
        blurb: "Connect OpenClaw to the LobsterPot iOS app via the LobsterPot bridge.",
        markdownCapable: true
      },

      capabilities: {
        chatTypes: ["direct"]
      },

      config: {
        listAccountIds: (_cfg: OpenClawConfig) => [DEFAULT_ACCOUNT_ID],

        resolveAccount: (cfg: OpenClawConfig, accountId?: string | null): LobsterPotResolvedAccount => {
          return resolveLobsterPotAccount(cfg as Record<string, unknown>, accountId ?? DEFAULT_ACCOUNT_ID);
        },

        inspectAccount: (cfg: OpenClawConfig, accountId?: string | null) => {
          return inspectLobsterPotAccount(cfg as Record<string, unknown>, accountId);
        },

        isConfigured: (account: LobsterPotResolvedAccount) => {
          return Boolean(account.bridgeUrl) && Boolean(account.token);
        }
      }
    },

    // DM security: enforce allowlist/pairing policy for iOS device IDs
    security: {
      dm: {
        channelKey: "lobsterpot",
        resolvePolicy: (account) => account.dmPolicy,
        resolveAllowFrom: (account) => account.allowFrom,
        defaultPolicy: "allowlist"
      }
    },

    // Pairing: generate a code delivered to the iOS device
    pairing: {
      text: {
        idLabel: "iOS device ID (e.g. ios:primary)",
        message: "Enter this pairing code in your LobsterPot app:",
        notify: async ({ id, message }) => {
          // Real delivery handled by the bridge; plugin just logs.
          console.log(`[lobsterpot] pairing code for ${id}: ${message}`);
        }
      }
    },

    // Threading: DM-style inline replies
    threading: {
      topLevelReplyToMode: "reply"
    },

    // Outbound: the sendText impl is patched at runtime by registerFull.
    // deliveryMode must be declared here; "direct" = plugin sends to platform directly.
    outbound: {
      attachedResults: {
        channel: "lobsterpot",
        sendText: async (ctx) => {
          // ctx.to is the LobsterPot bridge conversation id. For thread-bound
          // subagent announces, OpenClaw resolves this via the registered
          // SessionBindingAdapter so it points at the bound conversation.
          const result = sendOutboundText(ctx.to, ctx.text ?? "", "final");
          if (!result) {
            return { messageId: `dropped-${Date.now()}` };
          }
          return { messageId: result.messageId };
        }
      },
      base: {
        deliveryMode: "direct"
      }
    }
  });
}

export const lobsterPotPlugin = buildLobsterPotPlugin();
