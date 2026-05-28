import { createHash, randomBytes, randomUUID } from "node:crypto";

export function nowIso(): string {
  return new Date().toISOString();
}

export function createId(): string {
  return randomUUID();
}

export function createToken(prefix: string): string {
  return `${prefix}_${randomBytes(32).toString("base64url")}`;
}

export function sha256(input: string): string {
  return createHash("sha256").update(input).digest("hex");
}

export function safeJsonParse(input: string): unknown {
  try {
    return JSON.parse(input) as unknown;
  } catch {
    return null;
  }
}

export function normalizeBaseUrl(input: string): string {
  return input.replace(/\/+$/, "");
}
