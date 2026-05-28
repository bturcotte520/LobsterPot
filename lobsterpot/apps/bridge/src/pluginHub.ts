import type { Server } from "node:http";
import { randomUUID } from "node:crypto";
import { WebSocketServer, type RawData, type WebSocket } from "ws";
import {
  LOBSTERPOT_PROTOCOL_VERSION,
  parsePluginEvent,
  type BridgeToPluginEvent,
  type InboundMessage,
  type PluginConnectionStatus,
  type PluginHello,
  type PluginToBridgeEvent
} from "@lobsterpot/protocol";
import { nowIso, safeJsonParse } from "@lobsterpot/shared";
import type { BridgeDatabase } from "./db.js";
import type { EventBus } from "./eventBus.js";

type ActivePlugin = {
  connectionId: string;
  socket: WebSocket;
  instanceId: string;
  tokenId: string;
  capabilities: string[];
  lastSeenAt: string;
};

export class PluginHub {
  private readonly activeByInstance = new Map<string, ActivePlugin>();

  constructor(
    private readonly database: BridgeDatabase,
    private readonly events: EventBus
  ) {}

  attach(server: Server): void {
    const wss = new WebSocketServer({ noServer: true });

    server.on("upgrade", (request, socket, head) => {
      const url = new URL(request.url ?? "/", "http://127.0.0.1");
      if (url.pathname !== "/api/openclaw/connect") {
        return;
      }
      wss.handleUpgrade(request, socket, head, (ws) => {
        this.acceptSocket(ws);
      });
    });
  }

  status(): PluginConnectionStatus {
    const active = this.firstActive();
    if (!active) {
      return {
        connected: false,
        status: "waiting",
        instanceId: null,
        lastSeenAt: null,
        capabilities: []
      };
    }
    return {
      connected: active.socket.readyState === active.socket.OPEN,
      status: active.socket.readyState === active.socket.OPEN ? "connected" : "stale",
      instanceId: active.instanceId,
      lastSeenAt: active.lastSeenAt,
      capabilities: active.capabilities
    };
  }

  sendToPlugin(event: BridgeToPluginEvent, instanceId?: string | null): boolean {
    const active = instanceId ? this.activeByInstance.get(instanceId) : this.firstActive();
    if (!active || active.socket.readyState !== active.socket.OPEN) {
      return false;
    }
    active.socket.send(JSON.stringify(event));
    return true;
  }

  sendInboundMessage(event: InboundMessage, instanceId?: string | null): boolean {
    return this.sendToPlugin(event, instanceId);
  }

  private firstActive(): ActivePlugin | null {
    for (const active of this.activeByInstance.values()) {
      if (active.socket.readyState === active.socket.OPEN) return active;
    }
    return null;
  }

  private acceptSocket(socket: WebSocket): void {
    let authenticated = false;

    const fail = (code: BridgeToPluginEvent & { type: "hello.error" }) => {
      socket.send(JSON.stringify(code));
      socket.close();
    };

    socket.once("message", (data) => {
      const raw = parseRaw(data);
      const parsed = safeJsonParse(raw);
      const event = parsePluginEventSafe(parsed);

      if (!event || event.type !== "hello") {
        fail({
          type: "hello.error",
          code: "invalid_payload",
          message: "First frame must be a hello event."
        });
        return;
      }

      const token = this.database.validateBridgeToken(event.token);
      if (!token) {
        fail({
          type: "hello.error",
          code: "invalid_token",
          message: "Bridge token was not recognized."
        });
        return;
      }

      const instance = this.database.getOpenClawInstanceByTokenId(token.id);
      const openclawInstanceId = instance?.id ?? event.instanceId;

      authenticated = true;
      const connectionId = randomUUID();
      this.activeByInstance.get(openclawInstanceId)?.socket.close();
      this.activeByInstance.set(openclawInstanceId, {
        connectionId,
        socket,
        instanceId: openclawInstanceId,
        tokenId: token.id,
        capabilities: event.capabilities,
        lastSeenAt: nowIso()
      });

      console.log(`[bridge] plugin connected instance=${openclawInstanceId} connection=${connectionId}`);

      this.database.upsertPluginConnection({
        id: connectionId,
        bridgeTokenId: token.id,
        instanceId: openclawInstanceId,
        status: "connected",
        capabilities: event.capabilities
      });

      socket.send(JSON.stringify({
        type: "hello.ok",
        protocol: LOBSTERPOT_PROTOCOL_VERSION,
        connectionId,
        serverTime: Date.now(),
        resumeCursor: event.resumeCursor ?? null
      } satisfies BridgeToPluginEvent));

      this.events.publish({
        direction: "in",
        type: "plugin.connected",
        payload: sanitizeHello(event)
      });

      socket.on("message", (message) => this.onPluginMessage(openclawInstanceId, message));
      socket.on("close", (code, reason) => this.onPluginClose(connectionId, code, reason.toString("utf8")));
      socket.on("error", (error) => {
        console.warn(`[bridge] plugin socket error connection=${connectionId}: ${error.message}`);
        this.onPluginClose(connectionId);
      });
    });

    socket.on("close", () => {
      if (!authenticated) return;
    });
  }

  private onPluginMessage(instanceId: string, data: RawData): void {
    const parsed = safeJsonParse(parseRaw(data));
    const event = parsePluginEventSafe(parsed);
    if (!event || event.type === "hello") return;

    const active = this.activeByInstance.get(instanceId);
    if (active) {
      active.lastSeenAt = nowIso();
    }

    this.handlePluginEvent(instanceId, event);
  }

  private handlePluginEvent(instanceId: string, event: PluginToBridgeEvent): void {
    switch (event.type) {
      case "outbound.message": {
        console.log(`[bridge] plugin outbound.message conversation=${event.conversationId} status=${event.status}`);
        this.database.createMessage({
          conversationId: event.conversationId,
          role: "assistant",
          content: event.text,
          status: event.status,
          sourceEventId: event.id
        });
        this.events.publish({
          direction: "in",
          type: event.type,
          conversationId: event.conversationId,
          payload: event
        });
        break;
      }
      case "outbound.progress":
      case "outbound.approval.requested":
      case "delivery.receipt":
      case "presence.heartbeat":
      case "sync.request": {
        this.events.publish({
          direction: "in",
          type: event.type,
          conversationId: "conversationId" in event ? (event.conversationId ?? null) : null,
          payload: event
        });
        break;
      }
      case "hello": {
        break;
      }
    }
  }

  private onPluginClose(connectionId: string, code?: number, reason?: string): void {
    const active = [...this.activeByInstance.values()].find((entry) => entry.connectionId === connectionId);
    if (!active) return;
    console.log(`[bridge] plugin disconnected connection=${connectionId}${code ? ` code=${code}` : ""}${reason ? ` reason=${reason}` : ""}`);
    this.database.markPluginStale(connectionId);
    this.events.publish({
      direction: "in",
      type: "plugin.disconnected",
      payload: { connectionId }
    });
    this.activeByInstance.delete(active.instanceId);
  }
}

function parseRaw(data: RawData): string {
  if (typeof data === "string") return data;
  if (Buffer.isBuffer(data)) return data.toString("utf8");
  return Buffer.concat(data as Buffer[]).toString("utf8");
}

function parsePluginEventSafe(input: unknown): PluginToBridgeEvent | null {
  try {
    return parsePluginEvent(input);
  } catch {
    return null;
  }
}

function sanitizeHello(
  event: PluginHello
): Omit<PluginHello, "token"> & { token: "[redacted]" } {
  return { ...event, token: "[redacted]" };
}
