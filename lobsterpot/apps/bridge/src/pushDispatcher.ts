import type { PublicBridgeEvent } from "@lobsterpot/protocol";
import type { BridgeDatabase } from "./db.js";
import type { EventBus } from "./eventBus.js";
import type { PushRelayClient } from "./pushRelay.js";

/**
 * Listens for outbound.message events and dispatches push notifications
 * via the configured push relay.  No-ops gracefully when the relay is
 * unconfigured or the device has no APNs token.
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

    // Extract the text from the event payload (best-effort)
    const payload = event.payload as Record<string, unknown>;
    const text = typeof payload.text === "string" ? payload.text : "New message";
    const conversationId = event.conversationId ?? undefined;

    // Count unread as a badge hint (rough proxy: messages after last sync)
    // For now, send badge = 1; a richer approach would count unseen messages.
    await this.relay.send(reg.relay_handle, reg.relay_grant, {
      title: "LobsterPot",
      body: text.length > 120 ? text.slice(0, 117) + "…" : text,
      conversationId,
      badge: 1
    });
  }
}
