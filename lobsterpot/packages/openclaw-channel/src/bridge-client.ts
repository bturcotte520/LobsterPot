import WebSocket from "ws";
import {
  LOBSTERPOT_PROTOCOL_VERSION,
  parseBridgeEvent,
  type BridgeToPluginEvent,
  type InboundMessage,
  type PluginToBridgeEvent
} from "@lobsterpot/protocol";
import { createId, nowIso, safeJsonParse } from "@lobsterpot/shared";

export type LobsterPotBridgeClientEvents = {
  inboundMessage: (event: InboundMessage) => void | Promise<void>;
  connected?: () => void;
  disconnected?: () => void;
  error?: (error: Error) => void;
};

/**
 * WebSocket client that connects outbound from the OpenClaw plugin to the
 * LobsterPot bridge. This is the transport layer: the bridge is the "platform"
 * and this client is how the plugin receives iOS messages and sends replies.
 */
export class LobsterPotBridgeClient {
  private socket: WebSocket | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private stopped = false;
  private reconnectDelayMs = 2_000;

  constructor(
    private readonly bridgeUrl: string,
    private readonly token: string,
    private readonly instanceId: string,
    private readonly events: LobsterPotBridgeClientEvents
  ) {}

  start(): void {
    this.stopped = false;
    this.connect();
  }

  stop(): void {
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.socket?.close();
    this.socket = null;
  }

  send(event: PluginToBridgeEvent): boolean {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return false;
    this.socket.send(JSON.stringify(event));
    return true;
  }

  /** Send a final text reply to a conversation. Returns true if the frame was sent. */
  sendTextReply(conversationId: string, text: string, status: "streaming" | "final" = "final"): boolean {
    return this.send({
      type: "outbound.message",
      id: createId(),
      conversationId,
      messageId: createId(),
      role: "assistant",
      text,
      status,
      createdAt: nowIso()
    });
  }

  /** Resolve the HTTP base URL for direct bridge API calls (uses http/https, not ws). */
  private get httpBaseUrl(): string {
    const u = new URL(this.bridgeUrl);
    if (u.protocol === "ws:") u.protocol = "http:";
    if (u.protocol === "wss:") u.protocol = "https:";
    return u.toString().replace(/\/+$/, "");
  }

  /** POST /api/plugin/conversations — create a bridge conversation from the plugin side. */
  async createConversation(input: {
    title: string;
    purpose?: string | null;
    kind?: "main" | "subagent" | "specialist" | "support" | "system";
    openclawSessionKey?: string | null;
    openclawAgentId?: string | null;
  }): Promise<{ id: string; title: string }> {
    const res = await fetch(`${this.httpBaseUrl}/api/plugin/conversations`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.token}`
      },
      body: JSON.stringify({
        title: input.title,
        purpose: input.purpose ?? null,
        kind: input.kind ?? "specialist",
        openclawSessionKey: input.openclawSessionKey ?? null,
        openclawAgentId: input.openclawAgentId ?? null
      })
    });
    if (!res.ok) {
      throw new Error(`createConversation failed: HTTP ${res.status}`);
    }
    const data = await res.json() as { conversation: { id: string; title: string } };
    return { id: data.conversation.id, title: data.conversation.title };
  }

  // ── Private ─────────────────────────────────────────────────────────────────

  private connect(): void {
    if (this.stopped) return;

    const url = new URL(this.bridgeUrl);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    url.pathname = "/api/openclaw/connect";

    const socket = new WebSocket(url);
    this.socket = socket;

    socket.on("open", () => {
      this.reconnectDelayMs = 2_000; // reset backoff on successful connection
      socket.send(JSON.stringify({
        type: "hello",
        protocol: LOBSTERPOT_PROTOCOL_VERSION,
        channel: "lobsterpot",
        instanceId: this.instanceId,
        token: this.token,
        capabilities: ["text", "progress", "approvals", "receipts"]
      } satisfies PluginToBridgeEvent));
    });

    socket.on("message", (data) => {
      const raw = typeof data === "string" ? data : (data as Buffer).toString("utf8");
      const parsed = safeJsonParse(raw);
      let event: BridgeToPluginEvent;
      try {
        event = parseBridgeEvent(parsed);
      } catch (error) {
        this.events.error?.(error instanceof Error ? error : new Error(String(error)));
        return;
      }
      void this.handleBridgeEvent(event);
    });

    socket.on("close", () => {
      this.events.disconnected?.();
      this.scheduleReconnect();
    });

    socket.on("error", (error) => {
      this.events.error?.(error instanceof Error ? error : new Error(String(error)));
    });
  }

  private async handleBridgeEvent(event: BridgeToPluginEvent): Promise<void> {
    switch (event.type) {
      case "hello.ok":
        this.events.connected?.();
        break;
      case "hello.error":
        this.events.error?.(new Error(`Bridge rejected connection: ${event.message}`));
        this.stop();
        break;
      case "inbound.message":
        await this.events.inboundMessage(event);
        break;
      case "presence.heartbeat":
        // Echo heartbeat back
        this.send({ type: "presence.heartbeat", id: createId(), sentAt: nowIso() });
        break;
      case "delivery.receipt":
      case "sync.snapshot":
      case "inbound.approval.respond":
        break;
    }
  }

  private scheduleReconnect(): void {
    if (this.stopped) return;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = setTimeout(() => {
      this.reconnectDelayMs = Math.min(this.reconnectDelayMs * 2, 30_000);
      this.connect();
    }, this.reconnectDelayMs);
  }
}
