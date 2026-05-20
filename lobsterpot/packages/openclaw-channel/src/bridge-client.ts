import WebSocket from "ws";
import {
  LOBSTERPOT_PROTOCOL_VERSION,
  parseBridgeEvent,
  type BridgeToPluginEvent,
  type InboundMessage,
  type PluginToBridgeEvent
} from "@lobsterpot/protocol";
import { createId, nowIso, safeJsonParse } from "@lobsterpot/shared";
import type { LobsterPotChannelConfig } from "./config.js";

export type LobsterPotBridgeClientEvents = {
  inboundMessage: (event: InboundMessage) => void | Promise<void>;
  connected?: () => void;
  disconnected?: () => void;
  error?: (error: Error) => void;
};

export class LobsterPotBridgeClient {
  private socket: WebSocket | null = null;
  private reconnectTimer: NodeJS.Timeout | null = null;
  private stopped = false;

  constructor(
    private readonly config: LobsterPotChannelConfig,
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

  sendTextReply(conversationId: string, text: string): boolean {
    return this.send({
      type: "outbound.message",
      id: createId(),
      conversationId,
      messageId: createId(),
      role: "assistant",
      text,
      status: "final",
      createdAt: nowIso()
    });
  }

  private connect(): void {
    const url = new URL(this.config.bridgeUrl);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    url.pathname = "/api/openclaw/connect";

    const socket = new WebSocket(url);
    this.socket = socket;

    socket.on("open", () => {
      socket.send(JSON.stringify({
        type: "hello",
        protocol: LOBSTERPOT_PROTOCOL_VERSION,
        channel: "lobsterpot",
        instanceId: this.instanceId,
        token: this.config.token,
        capabilities: ["text", "progress", "approvals", "receipts"]
      }));
    });

    socket.on("message", (data) => {
      const parsed = safeJsonParse(data.toString());
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
        this.events.error?.(new Error(event.message));
        this.stop();
        break;
      case "inbound.message":
        await this.events.inboundMessage(event);
        break;
      case "presence.heartbeat":
      case "delivery.receipt":
      case "sync.snapshot":
      case "inbound.approval.respond":
        break;
    }
  }

  private scheduleReconnect(): void {
    if (this.stopped) return;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = setTimeout(() => this.connect(), 2_000);
  }
}
