import { describe, expect, it } from "vitest";
import { resolveLobsterPotConfig } from "../src/config.js";

describe("lobsterpot config", () => {
  it("normalizes bridge urls", () => {
    const config = resolveLobsterPotConfig({
      bridgeUrl: "https://example.com/",
      token: "lobsterpot_test"
    });
    expect(config.bridgeUrl).toBe("https://example.com");
    expect(config.allowFrom).toEqual(["ios:primary"]);
  });
});
