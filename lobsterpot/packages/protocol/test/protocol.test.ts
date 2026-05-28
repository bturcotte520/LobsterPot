import { describe, it, expect } from "vitest";
import {
  LOBSTERPOT_PROTOCOL_VERSION,
  inboundMessageSchema,
  outboundMessageSchema,
  pluginHelloSchema,
  pluginToBridgeEventSchema,
  bridgeToPluginEventSchema,
  parsePluginEvent,
  parseBridgeEvent
} from "../src/index.js";

describe("protocol version", () => {
  it("is 1", () => expect(LOBSTERPOT_PROTOCOL_VERSION).toBe(1));
});

describe("inboundMessageSchema", () => {
  it("parses a valid inbound message", () => {
    const msg = inboundMessageSchema.parse({
      type: "inbound.message",
      id: "evt-1",
      conversationId: "00000000-0000-0000-0000-000000000001",
      senderId: "ios:primary",
      text: "Hello",
      createdAt: "2026-01-01T00:00:00.000Z",
      metadata: {}
    });
    expect(msg.type).toBe("inbound.message");
    expect(msg.text).toBe("Hello");
  });
});

describe("outboundMessageSchema", () => {
  it("parses a valid outbound message", () => {
    const msg = outboundMessageSchema.parse({
      type: "outbound.message",
      id: "evt-2",
      conversationId: "00000000-0000-0000-0000-000000000001",
      messageId: "msg-1",
      role: "assistant",
      text: "Hi there!",
      status: "final",
      createdAt: "2026-01-01T00:00:00.000Z"
    });
    expect(msg.status).toBe("final");
  });
});

describe("pluginHelloSchema", () => {
  it("rejects a bad token prefix", () => {
    expect(() => pluginHelloSchema.parse({
      type: "hello",
      protocol: 1,
      channel: "lobsterpot",
      instanceId: "inst-1",
      token: "bad_token",
      capabilities: []
    })).toThrow();
  });
});

describe("pluginToBridgeEventSchema / parsePluginEvent", () => {
  it("discriminates on type", () => {
    const hb = parsePluginEvent({
      type: "presence.heartbeat",
      id: "hb-1",
      sentAt: "2026-01-01T00:00:00.000Z"
    });
    expect(hb.type).toBe("presence.heartbeat");
  });
});

describe("bridgeToPluginEventSchema / parseBridgeEvent", () => {
  it("parses hello.ok", () => {
    const event = parseBridgeEvent({
      type: "hello.ok",
      protocol: 1,
      connectionId: "00000000-0000-0000-0000-000000000002",
      serverTime: 1234567890
    });
    expect(event.type).toBe("hello.ok");
  });
});
