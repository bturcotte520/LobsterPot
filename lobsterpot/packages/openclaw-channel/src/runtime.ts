/**
 * LobsterPot plugin runtime.
 *
 * Started from registerFull(api). Owns:
 *   - The bridge WebSocket client (inbound + outbound transport)
 *   - The session binding adapter (subagent thread auto-creation)
 *   - The inbound dispatch pipeline (bridge frames → channel turns)
 *   - The outbound delivery target lookup (session → bridge conversation)
 */

import type { OpenClawPluginApi } from "openclaw/plugin-sdk/channel-core";
import { DEFAULT_ACCOUNT_ID } from "openclaw/plugin-sdk/account-id";
import { dispatchInboundDirectDmWithRuntime } from "openclaw/plugin-sdk/channel-inbound";
import {
  registerSessionBindingAdapter,
  unregisterSessionBindingAdapter
} from "openclaw/plugin-sdk/conversation-runtime";
import { createId } from "@lobsterpot/shared";
import type { InboundMessage } from "@lobsterpot/protocol";
import { LobsterPotBridgeClient } from "./bridge-client.js";
import { LobsterPotBindingAdapter } from "./binding-adapter.js";
import { resolveLobsterPotAccount } from "./config.js";

const CHANNEL_ID = "lobsterpot";
const CHANNEL_LABEL = "LobsterPot";

type ActiveRuntime = {
  instanceId: string;
  client: LobsterPotBridgeClient;
  adapter: LobsterPotBindingAdapter;
  accountId: string;
  stop: () => void;
};

let activeRuntime: ActiveRuntime | null = null;

const materializedConversationIdsBySession = new Map<string, string>();

// Session keys and labels of real OpenClaw subagent threads already materialized
// in this runtime lifetime.
const materializedSpecialistLabels = new Set<string>();

export function startLobsterPotRuntime(api: OpenClawPluginApi): ActiveRuntime | null {
  // Stop any previous runtime owned by this module before starting a new one.
  activeRuntime?.stop();
  activeRuntime = null;

  const cfg = api.config;
  let account: ReturnType<typeof resolveLobsterPotAccount>;
  try {
    account = resolveLobsterPotAccount(cfg as Record<string, unknown>);
  } catch (err) {
    api.logger.error(`[lobsterpot] invalid config: ${String(err)}`);
    return null;
  }

  const accountId = account.accountId ?? DEFAULT_ACCOUNT_ID;
  const instanceId = createId();

  const client = new LobsterPotBridgeClient(
    account.bridgeUrl,
    account.token,
    instanceId,
    {
      connected: () => api.logger.info("[lobsterpot] connected to bridge"),
      disconnected: () => api.logger.info("[lobsterpot] disconnected from bridge"),
      error: (err) => api.logger.error(`[lobsterpot] bridge error: ${err.message}`),
      inboundMessage: async (event: InboundMessage) => {
        await handleInboundMessage(api, event);
      }
    }
  );

  const adapter = new LobsterPotBindingAdapter(
    accountId,
    {
      createConversation: (input) => client.createConversation(input)
    },
    api.logger
  );

  client.start();
  registerSessionBindingAdapter(adapter);

  const runtime: ActiveRuntime = {
    instanceId,
    client,
    adapter,
    accountId,
    stop: () => {
      // Only clear the global if we are still the active runtime.
      if (activeRuntime === runtime) {
        activeRuntime = null;
      }
      unregisterSessionBindingAdapter({ channel: CHANNEL_ID, accountId, adapter });
      client.stop();
    }
  };

  activeRuntime = runtime;
  return runtime;
}

export function stopLobsterPotRuntime(): void {
  activeRuntime?.stop();
  activeRuntime = null;
}

export async function materializeOpenClawSubagentSession(input: {
  childSessionKey: string;
  agentId: string;
  label?: string;
  runId?: string;
  mode?: "run" | "session";
  requesterConversationId?: string | null;
}): Promise<string | null> {
  if (!activeRuntime) return null;
  const sessionKey = input.childSessionKey.trim();
  if (!sessionKey) return null;

  const existingConversationId = materializedConversationIdsBySession.get(sessionKey);
  if (existingConversationId) return existingConversationId;

  const title = input.label?.trim() || `Subagent ${sessionKey.split(":").pop()?.slice(0, 8) ?? ""}`.trim();
  const conversationId = (await activeRuntime.client.createConversation({
    title,
    kind: "subagent",
    openclawSessionKey: sessionKey,
    openclawAgentId: input.agentId
  })).id;

  materializedSpecialistLabels.add(sessionKey);
  materializedSpecialistLabels.add(title.toLowerCase());
  materializedConversationIdsBySession.set(sessionKey, conversationId);
  activeRuntime.adapter.bindExistingConversation({
    conversationId,
    targetSessionKey: sessionKey,
    targetKind: "subagent",
    parentConversationId: input.requesterConversationId ?? null,
    metadata: {
      label: input.label,
      agentId: input.agentId,
      runId: input.runId,
      mode: input.mode
    }
  });
  activeRuntime.client.sendTextReply(
    conversationId,
    `${title} is connected to OpenClaw session ${sessionKey}.`,
    "final"
  );
  return conversationId;
}

/**
 * Send a text reply to a specific bridge conversation. Used both by the
 * inbound deliver callback and by the outbound adapter (subagent announces,
 * approval prompts, etc.).
 */
export function sendOutboundText(conversationId: string, text: string, status: "streaming" | "final" = "final"): { messageId: string } | null {
  if (!activeRuntime) return null;
  const ok = activeRuntime.client.sendTextReply(conversationId, text, status);
  if (!ok) return null;

  return { messageId: createId() };
}

// ── Inbound dispatch ─────────────────────────────────────────────────────────

async function handleInboundMessage(
  api: OpenClawPluginApi,
  event: InboundMessage
): Promise<void> {
  const cfg = api.config;
  let account: ReturnType<typeof resolveLobsterPotAccount>;
  try {
    account = resolveLobsterPotAccount(cfg as Record<string, unknown>);
  } catch {
    api.logger.error("[lobsterpot] cannot dispatch inbound: config missing");
    return;
  }

  const { conversationId, senderId, text, metadata } = event;
  const accountId = account.accountId ?? DEFAULT_ACCOUNT_ID;
  const senderAddress = senderId;
  const recipientAddress = `lobsterpot:${accountId}`;

  // If this conversation is bound to a subagent, the binding service routes
  // the inbound turn to that subagent session automatically. We dispatch via
  // the standard direct-dm helper using the conversation id as the peer id;
  // OpenClaw's session resolution picks up the binding via the registered
  // SessionBindingAdapter.
  const peerId = conversationId;

  const conversationLabel =
    metadata.conversationTitle ?? `LobsterPot ${conversationId.slice(0, 8)}`;

  if (metadata.openclawSessionKey) {
    activeRuntime?.adapter.bindExistingConversation({
      conversationId,
      targetSessionKey: metadata.openclawSessionKey,
      targetKind: "subagent",
      parentConversationId: null,
      metadata: {
        label: metadata.conversationTitle,
        agentId: metadata.openclawAgentId
      }
    });
  }

  await dispatchInboundDirectDmWithRuntime({
    cfg: cfg as Parameters<typeof dispatchInboundDirectDmWithRuntime>[0]["cfg"],
    runtime: api.runtime,
    channel: CHANNEL_ID,
    channelLabel: CHANNEL_LABEL,
    accountId,
    peer: { kind: "direct", id: peerId },
    senderId: senderAddress,
    senderAddress,
    recipientAddress,
    conversationLabel,
    rawBody: text,
    messageId: event.id,
    bodyForAgent: buildBodyForAgent({
      text,
      title: metadata.conversationTitle ?? null,
      purpose: metadata.conversationPurpose ?? null,
      kind: metadata.conversationKind ?? null
    }),
    extraContext: {
      lobsterpotConversationId: conversationId,
      lobsterpotConversationKind: metadata.conversationKind ?? null
    },
    deliver: async (payload) => {
      const replyText = payload.text ?? "";
      if (!replyText && !payload.mediaUrls?.length) return;

      // Inbound-turn replies always go back to the originating conversation.
      sendOutboundText(conversationId, replyText, "final");
    },
    onRecordError: (err) => {
      api.logger.error(`[lobsterpot] session record error: ${String(err)}`);
    },
    onDispatchError: (err, info) => {
      api.logger.error(`[lobsterpot] dispatch error (${info.kind}): ${String(err)}`);
    }
  });
}

export function extractRequestedSubagentLabel(prompt: string): string | null {
  const quoted = /label\s+it\s+["“]([^"”]+)["”]/i.exec(prompt);
  if (quoted?.[1]?.trim()) return quoted[1].trim();
  const named = /(?:called|named)\s+["“]([^"”]+)["”]/i.exec(prompt);
  if (named?.[1]?.trim()) return named[1].trim();
  const forTopic = /(?:subagent|agent|specialist|tutor)\s+for\s+([A-Za-z][^\n.?!,]{2,80})/i.exec(prompt);
  if (forTopic?.[1]?.trim()) return labelFromTopic(forTopic[1]);
  const toHelp = /(?:create|make|start|open|set\s+up|spin\s+up)\s+(?:(?:a|an|the)\s+)?(?:new\s+)?(?:subagent|agent|specialist|tutor)\s+to\s+([^\n.?!]{3,100})/i.exec(prompt);
  if (toHelp?.[1]?.trim()) return labelFromTopic(toHelp[1]);
  const createTutor = /(?:create|make|start|open|set\s+up|spin\s+up)\s+(?:(?:a|an|the)\s+)?([A-Za-z][^\n.?!,]{2,60}?)\s+(?:subagent|agent|specialist|tutor)\b/i.exec(prompt);
  if (createTutor?.[1]?.trim()) return labelFromTopic(createTutor[1]);
  return null;
}

function isSubagentThreadRequest(prompt: string): boolean {
  return /\b(spawn|create|make|start|open|set\s+up|spin\s+up)\b/i.test(prompt)
    && /\b(subagent|agent|specialist|tutor)\b/i.test(prompt);
}

function labelFromTopic(topic: string): string {
  if (/\b(fitness|get\s+in\s+shape|work\s*out|exercise|strength|running|nutrition)\b/i.test(topic)) {
    return "Fitness Coach";
  }
  const cleaned = topic
    .replace(/\b(help(?:ing)?\s+me\s+)?(?:learn|practice|study)\b/gi, "")
    .replace(/\bhelp(?:ing)?\s+(?:me|us)\b/gi, "")
    .replace(/\b(?:beginner|intermediate|advanced|basic)\b/gi, "")
    .replace(/\b(?:tutoring|practice|lessons?|help)\b/gi, "")
    .replace(/\b(?:with|about|on|for|me|my)\b/gi, "")
    .replace(/\s+/g, " ")
    .trim();
  const base = cleaned || topic.trim();
  const words = base.split(/\s+/).slice(0, 4);
  const titled = words.map((word) => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase()).join(" ");
  return /\b(tutor|agent|specialist|subagent)\b/i.test(titled) ? titled : `${titled} Tutor`;
}

export function extractSubagentPurpose(prompt: string): string | null {
  const match = /subagent(?:'s)?\s+job\s+is\s+to\s+([^\n.]+(?:\.[^\n]*)?)/i.exec(prompt);
  if (!match?.[1]) return null;
  return match[1].trim().slice(0, 240);
}

export function extractSubagentAnnounceText(replyText: string, label: string): string | null {
  if (!replyText.toLowerCase().includes(label.toLowerCase())) return null;

  const markerMatch = /(?:here(?:'|’)s|here is)\s+what\s+it\s+sent\s*:/i.exec(replyText);
  if (!markerMatch) return null;

  let body = replyText.slice(markerMatch.index + markerMatch[0].length).trim();
  body = body.replace(/^[-—\s]+/m, "").trim();
  body = body.replace(/\n-{3,}\n[\s\S]*$/m, "").trim();
  return body.length > 0 ? body : null;
}

/**
 * Detects when the main agent has announced a newly spawned specialist in its
 * reply to the user (e.g. "Chinese Tutor is ready! Here's its intro: ...").
 * Returns the label and the body that should become the first message in the
 * dedicated specialist thread, if a recognizable pattern is found.
 */
export function extractSpecialistAnnouncement(text: string): { label: string; body: string } | null {
  if (!text) return null;

  // Pattern 1: "Foo Tutor is ready! Here's its intro: --- body ---"
  const readyMarker = /(?:^|\n)([^\n]+?)\s+is\s+ready[!.]?\s*(?:Here(?:'|’)s|Here is)\s+its\s+intro[:：]?\s*/i.exec(text);
  if (readyMarker?.[1]) {
    const label = normalizeAnnouncementLabel(readyMarker[1].trim());
    let body = text.slice(readyMarker.index + readyMarker[0].length).trim();
    body = body.replace(/^[-—\s]+/m, "").trim();
    body = body.replace(/\n-{3,}\n[\s\S]*$/m, "").trim();
    if (label && body.length > 0) {
      return { label, body };
    }
  }

  // Pattern 2: older "Xxx subagent spawned! ... Its intro will arrive shortly."
  // In this case we usually only have a short placeholder; we still create the
  // thread so the real intro (which appears in the terminal) can be followed up.
  const spawned = /([A-Za-z][^\n]{2,40}?)\s+(?:Tutor|subagent)\s+(?:is\s+ready|spawned)/i.exec(text);
  if (spawned?.[1]) {
    const label = normalizeAnnouncementLabel(spawned[1].trim());
    // Try to capture everything after the first sentence as a weak body.
    const after = text.slice((spawned.index ?? 0) + spawned[0].length).trim();
    const body = after.length > 10 ? after.replace(/\n-{3,}\n[\s\S]*$/m, "").trim() : `${label} is ready.`;
    return { label, body };
  }

  return null;
}

function normalizeAnnouncementLabel(label: string): string {
  return label.replace(/^your\s+/i, "").replace(/\s+tutor$/i, " Tutor").trim();
}

export function buildBodyForAgent(params: {
  text: string;
  title?: string | null;
  purpose?: string | null;
  kind?: string | null;
}): string | undefined {
  if (params.kind !== "specialist" && params.kind !== "subagent" && !params.purpose) return undefined;

  const title = params.title?.trim() || "Specialist";
  const roleName = params.kind === "subagent" ? "subagent" : "specialist";
  const purpose = params.purpose?.trim() || `Help the user with this ${roleName} thread.`;
  return [
    `[LobsterPot ${roleName} thread]`,
    `You are the persistent ${roleName} conversation named "${title}".`,
    `Purpose: ${purpose}`,
    `Stay in this role across follow-up messages in this thread.`,
    `Do not claim to be the main agent unless the user asks about routing; explain you are the ${roleName} thread for this conversation.`,
    ``,
    `User message: ${params.text}`
  ].join("\n");
}
