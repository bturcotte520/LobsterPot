/**
 * Minimal APNs HTTP/2 provider.
 *
 * Uses Node's built-in `node:http2` + `node:crypto` — zero external deps.
 * Implements the JWT-based authentication required by Apple:
 *   https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns
 */

import { connect, type ClientHttp2Session } from "node:http2";
import { createSign } from "node:crypto";

export type ApnsConfig = {
  teamId: string;
  keyId: string;
  /** Contents of the .p8 EC private key file (PEM string) */
  privateKey: string;
  bundleId: string;
  production: boolean;
};

export type ApnsPayload = {
  alert?: { title?: string; body?: string; subtitle?: string };
  badge?: number;
  sound?: string;
  "thread-id"?: string;
  "content-available"?: 1;
  "mutable-content"?: 1;
  [key: string]: unknown;
};

export type ApnsResult =
  | { ok: true; apnsId: string | null }
  | { ok: false; status: number; reason: string };

const TOKEN_TTL_MS = 55 * 60_000; // Refresh JWT every 55 min (Apple limit is 60 min)

export class ApnsProvider {
  private readonly config: ApnsConfig;
  private session: ClientHttp2Session | null = null;
  private tokenCache: { token: string; builtAt: number } | null = null;

  constructor(config: ApnsConfig) {
    this.config = config;
  }

  async send(deviceToken: string, payload: ApnsPayload, extra?: {
    priority?: 5 | 10;
    pushType?: "alert" | "background" | "voip" | "location";
    collapseId?: string;
    expiration?: number;
  }): Promise<ApnsResult> {
    const host = this.config.production
      ? "api.push.apple.com"
      : "api.sandbox.push.apple.com";

    const session = this.getOrCreateSession(host);
    const jwtToken = this.getBearerToken();
    const body = JSON.stringify({ aps: payload });

    return new Promise((resolve) => {
      const req = session.request({
        ":method": "POST",
        ":path": `/3/device/${deviceToken}`,
        ":scheme": "https",
        ":authority": host,
        "authorization": `bearer ${jwtToken}`,
        "apns-push-type": extra?.pushType ?? "alert",
        "apns-priority": String(extra?.priority ?? 10),
        "apns-topic": this.config.bundleId,
        "content-type": "application/json",
        "content-length": Buffer.byteLength(body),
        ...(extra?.collapseId ? { "apns-collapse-id": extra.collapseId } : {}),
        ...(extra?.expiration !== undefined ? { "apns-expiration": String(extra.expiration) } : {})
      });

      req.setEncoding("utf8");
      let responseBody = "";
      let statusCode = 0;
      let apnsId: string | null = null;

      req.on("response", (headers) => {
        statusCode = Number(headers[":status"] ?? 0);
        apnsId = (headers["apns-id"] as string | undefined) ?? null;
      });

      req.on("data", (chunk: string) => { responseBody += chunk; });

      req.on("end", () => {
        if (statusCode === 200) {
          resolve({ ok: true, apnsId });
        } else {
          let reason = "Unknown";
          try {
            reason = (JSON.parse(responseBody) as { reason?: string }).reason ?? reason;
          } catch { /* ignore */ }
          resolve({ ok: false, status: statusCode, reason });
        }
      });

      req.on("error", (err: Error) => {
        // Destroy the session so it's recreated on next call
        this.session?.destroy();
        this.session = null;
        resolve({ ok: false, status: 0, reason: err.message });
      });

      req.write(body);
      req.end();
    });
  }

  destroy(): void {
    this.session?.destroy();
    this.session = null;
  }

  // ── Private ─────────────────────────────────────────────────────────────────

  private getOrCreateSession(host: string): ClientHttp2Session {
    if (!this.session || this.session.destroyed || this.session.closed) {
      this.session = connect(`https://${host}`);
      this.session.on("error", () => {
        this.session?.destroy();
        this.session = null;
      });
    }
    return this.session;
  }

  private getBearerToken(): string {
    const now = Date.now();
    if (this.tokenCache && (now - this.tokenCache.builtAt) < TOKEN_TTL_MS) {
      return this.tokenCache.token;
    }

    const header = base64url(JSON.stringify({ alg: "ES256", kid: this.config.keyId }));
    const payload = base64url(JSON.stringify({ iss: this.config.teamId, iat: Math.floor(now / 1000) }));
    const signingInput = `${header}.${payload}`;

    const sign = createSign("SHA256");
    sign.update(signingInput);
    // dsaEncoding: "ieee-p1363" gives raw r||s (what Apple expects), not DER
    const sig = sign.sign({ key: this.config.privateKey, dsaEncoding: "ieee-p1363" });
    const token = `${signingInput}.${base64url(sig)}`;

    this.tokenCache = { token, builtAt: now };
    return token;
  }
}

/** URL-safe base64 without padding */
function base64url(input: string | Buffer): string {
  const buf = typeof input === "string" ? Buffer.from(input) : input;
  return buf.toString("base64url");
}
