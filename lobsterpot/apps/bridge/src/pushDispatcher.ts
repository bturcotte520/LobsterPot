import type { PublicBridgeEvent } from "@lobsterpot/protocol";
import type { BridgeDatabase } from "./db.js";
import type { EventBus } from "./eventBus.js";
import type { PushRelayClient } from "./pushRelay.js";

/**
 * Listens for outbound.message events and dispatches push notifications
 * via the configured push relay.
 */
export class PushDispatcher {
  private readonly unsubscribe: () => void;

  constructor(
    private readonly database: BridgeDatabase,
    private readonly relay: PushRelayClient,
    events: EventBus
  ) {
    this.unsubscribe = events.subscribe((event) => this.handleEvent(event));
  }

  dispose(): void {
    this.unsubscribe();
  }

  private async handleEvent(event: PublicBridgeEvent): Promise<void> {
    if (event.type !== "outbound.message") return;

    const reg = this.database.getRelayRegistration();
    if (!reg) return;

    const payload = event.payload as Record<string, unknown>;
    if (payload["status"] === "streaming") return;

    const text = typeof payload["text"] === "string" ? payload["text"] : "New message";
    const conversationId = event.conversationId ?? undefined;
    const conversation = conversationId ? this.database.getConversation(conversationId) : null;

    await this.relay.send(reg.relay_handle, reg.relay_grant, {
      title: conversation?.title ?? "LobsterPot",
      body: text.length > 120 ? text.slice(0, 117) + "…" : text,
      conversationId,
      badge: 1
    });
  }
}
