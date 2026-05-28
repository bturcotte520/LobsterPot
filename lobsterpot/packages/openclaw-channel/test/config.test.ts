import { describe, it, expect } from "vitest";
import {
  resolveLobsterPotAccount,
  inspectLobsterPotAccount
} from "../src/config.js";

const validCfg = {
  channels: {
    lobsterpot: {
      bridgeUrl: "https://my-bridge.fly.dev",
      token: "lobsterpot_testtoken",
      dmPolicy: "allowlist",
      allowFrom: ["ios:primary"]
    }
  }
};

describe("resolveLobsterPotAccount", () => {
  it("resolves account from valid config", () => {
    const account = resolveLobsterPotAccount(validCfg);
    expect(account.bridgeUrl).toBe("https://my-bridge.fly.dev");
    expect(account.token).toBe("lobsterpot_testtoken");
    expect(account.dmPolicy).toBe("allowlist");
    expect(account.allowFrom).toEqual(["ios:primary"]);
    expect(account.accountId).toBeNull();
  });

  it("throws when bridgeUrl is missing", () => {
    expect(() => resolveLobsterPotAccount({
      channels: { lobsterpot: { token: "lobsterpot_t" } }
    })).toThrow();
  });

  it("throws when token is missing", () => {
    expect(() => resolveLobsterPotAccount({
      channels: { lobsterpot: { bridgeUrl: "https://x.example.com" } }
    })).toThrow();
  });

  it("applies default dmPolicy when omitted", () => {
    const account = resolveLobsterPotAccount({
      channels: { lobsterpot: { bridgeUrl: "https://x.example.com", token: "lobsterpot_t" } }
    });
    expect(account.dmPolicy).toBe("allowlist");
  });
});

describe("inspectLobsterPotAccount", () => {
  it("reports configured=true when both fields present", () => {
    const result = inspectLobsterPotAccount(validCfg);
    expect(result.configured).toBe(true);
    expect(result.enabled).toBe(true);
    expect(result.bridgeUrlStatus).toBe("available");
    expect(result.tokenStatus).toBe("available");
  });

  it("reports configured=false when channel section is missing", () => {
    const result = inspectLobsterPotAccount({ channels: {} });
    expect(result.configured).toBe(false);
    expect(result.bridgeUrlStatus).toBe("missing");
    expect(result.tokenStatus).toBe("missing");
  });

  it("reports bridgeUrlStatus=missing when only token is set", () => {
    const result = inspectLobsterPotAccount({
      channels: { lobsterpot: { token: "lobsterpot_t" } }
    });
    expect(result.bridgeUrlStatus).toBe("missing");
    expect(result.tokenStatus).toBe("available");
    expect(result.configured).toBe(false);
  });

  it("respects enabled: false", () => {
    const result = inspectLobsterPotAccount({
      channels: { lobsterpot: { ...validCfg.channels.lobsterpot, enabled: false } }
    });
    expect(result.enabled).toBe(false);
  });
});
