import type { PublicBridgeEvent } from "@lobsterpot/protocol";
import type { BridgeDatabase } from "./db.js";

type Subscriber = (event: PublicBridgeEvent) => void | Promise<void>;

export class EventBus {
  private readonly subscribers = new Set<Subscriber>();

  constructor(private readonly database: BridgeDatabase) {}

  publish(input: {
    direction: "in" | "out";
    type: string;
    conversationId?: string | null;
    payload: unknown;
  }): PublicBridgeEvent {
    const event = this.database.recordEvent(input);
    for (const subscriber of this.subscribers) {
      void subscriber(event);
    }
    return event;
  }

  subscribe(subscriber: Subscriber): () => void {
    this.subscribers.add(subscriber);
    return () => {
      this.subscribers.delete(subscriber);
    };
  }
}
