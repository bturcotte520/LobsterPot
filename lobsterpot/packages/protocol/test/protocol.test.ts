import { describe, expect, it } from "vitest";
import { LOBSTERPOT_PROTOCOL_VERSION, pluginHelloSchema } from "../src/index.js";

describe("protocol schemas", () => {
  it("accepts a valid plugin hello", () => {
    const parsed = pluginHelloSchema.parse({
      type: "hello",
      protocol: LOBSTERPOT_PROTOCOL_VERSION,
      channel: "lobsterpot",
      instanceId: "test-openclaw",
      token: "lobsterpot_test",
      capabilities: ["text"]
    });

    expect(parsed.instanceId).toBe("test-openclaw");
  });

  it("rejects non-lobsterpot tokens", () => {
    expect(() => pluginHelloSchema.parse({
      type: "hello",
      protocol: LOBSTERPOT_PROTOCOL_VERSION,
      channel: "lobsterpot",
      instanceId: "test-openclaw",
      token: "bad",
      capabilities: []
    })).toThrow();
  });
});
