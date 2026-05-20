import { describe, expect, it } from "vitest";
import {
  nowIso,
  createId,
  createToken,
  sha256,
  safeJsonParse,
  normalizeBaseUrl
} from "../src/index.js";

describe("nowIso", () => {
  it("returns an ISO 8601 string", () => {
    const ts = nowIso();
    expect(() => new Date(ts)).not.toThrow();
    expect(isNaN(new Date(ts).getTime())).toBe(false);
    expect(ts).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/);
  });

  it("returns values close to Date.now()", () => {
    const before = Date.now();
    const ts = nowIso();
    const after = Date.now();
    const parsed = new Date(ts).getTime();
    expect(parsed).toBeGreaterThanOrEqual(before);
    expect(parsed).toBeLessThanOrEqual(after);
  });
});

describe("createId", () => {
  it("returns a UUID v4", () => {
    const id = createId();
    expect(id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i);
  });

  it("returns unique values", () => {
    const ids = new Set(Array.from({ length: 1000 }, () => createId()));
    expect(ids.size).toBe(1000);
  });
});

describe("createToken", () => {
  it("uses the supplied prefix", () => {
    const token = createToken("lobsterpot");
    expect(token.startsWith("lobsterpot_")).toBe(true);
  });

  it("suffix is base64url (no +, /, =)", () => {
    const token = createToken("test");
    const suffix = token.split("_").slice(1).join("_");
    expect(suffix).toMatch(/^[A-Za-z0-9_-]+$/);
  });

  it("returns unique tokens", () => {
    const tokens = new Set(Array.from({ length: 100 }, () => createToken("x")));
    expect(tokens.size).toBe(100);
  });

  it("suffix is 43 chars (256 bits in base64url)", () => {
    // 32 bytes → base64url → 43 chars (no padding)
    const token = createToken("pfx");
    const suffix = token.slice("pfx_".length);
    expect(suffix.length).toBe(43);
  });
});

describe("sha256", () => {
  it("produces consistent 64-char hex output", () => {
    const hash = sha256("hello");
    expect(hash).toBe("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
    expect(hash).toHaveLength(64);
  });

  it("different inputs produce different hashes", () => {
    expect(sha256("a")).not.toBe(sha256("b"));
  });

  it("empty string has a known hash", () => {
    expect(sha256("")).toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  });
});

describe("safeJsonParse", () => {
  it("parses valid JSON", () => {
    expect(safeJsonParse('{"a":1}')).toEqual({ a: 1 });
    expect(safeJsonParse("[1,2,3]")).toEqual([1, 2, 3]);
    expect(safeJsonParse('"hello"')).toBe("hello");
  });

  it("returns null for invalid JSON", () => {
    expect(safeJsonParse("{bad json")).toBeNull();
    expect(safeJsonParse("")).toBeNull();
    expect(safeJsonParse("undefined")).toBeNull();
  });

  it("parses null literal", () => {
    expect(safeJsonParse("null")).toBeNull();
  });
});

describe("normalizeBaseUrl", () => {
  it("strips trailing slashes", () => {
    expect(normalizeBaseUrl("https://example.com/")).toBe("https://example.com");
    expect(normalizeBaseUrl("https://example.com///")).toBe("https://example.com");
  });

  it("leaves clean URLs unchanged", () => {
    expect(normalizeBaseUrl("https://example.com")).toBe("https://example.com");
    expect(normalizeBaseUrl("http://127.0.0.1:3000")).toBe("http://127.0.0.1:3000");
  });

  it("handles path prefixes without trailing slash", () => {
    expect(normalizeBaseUrl("https://example.com/bridge")).toBe("https://example.com/bridge");
  });
});
