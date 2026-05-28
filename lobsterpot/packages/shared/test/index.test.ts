import { describe, it, expect } from "vitest";
import { sha256, safeJsonParse, normalizeBaseUrl, createToken, nowIso } from "../src/index.js";

describe("sha256", () => {
  it("produces consistent hex digest", () => {
    const hash = sha256("hello");
    expect(hash).toBe("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
  });
});

describe("safeJsonParse", () => {
  it("parses valid JSON", () => {
    expect(safeJsonParse('{"a":1}')).toEqual({ a: 1 });
  });
  it("returns null for invalid JSON", () => {
    expect(safeJsonParse("not json")).toBeNull();
  });
});

describe("normalizeBaseUrl", () => {
  it("strips trailing slashes", () => {
    expect(normalizeBaseUrl("https://example.com//")).toBe("https://example.com");
  });
  it("leaves clean urls alone", () => {
    expect(normalizeBaseUrl("https://example.com")).toBe("https://example.com");
  });
});

describe("createToken", () => {
  it("starts with the given prefix", () => {
    const t = createToken("lobsterpot");
    expect(t.startsWith("lobsterpot_")).toBe(true);
  });
});

describe("nowIso", () => {
  it("returns an ISO timestamp string", () => {
    const ts = nowIso();
    expect(() => new Date(ts)).not.toThrow();
    expect(ts).toMatch(/^\d{4}-\d{2}-\d{2}T/);
  });
});
