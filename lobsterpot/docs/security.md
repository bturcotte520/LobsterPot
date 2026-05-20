# Security Model

## Threat model scope

LobsterPot is a single-user, self-hosted system. The primary concern is that an attacker who obtains the bridge URL must not be able to read conversations, send messages, or control the agent without a valid credential.

---

## Token types

### Bridge token (`lobsterpot_<base64url>`)

- Generated once by the bridge operator via `POST /api/setup/token`.
- Stored as a `SHA-256(token)` hash in the `bridge_tokens` table — the raw token is never persisted.
- Used exclusively by the OpenClaw channel plugin to authenticate its WebSocket connection.
- Long-lived; revoke by deleting the row or setting `revoked_at`.

### Device token (`device_<id>`)

- Issued per device after pairing (future: PKCE/code exchange).
- Sent as a `Bearer` header on all iOS → bridge API calls.
- Currently stored as-is in the bridge database. **Future milestone**: hash on storage, same as bridge tokens.

---

## Bridge API authentication

All iOS-facing API endpoints and the SSE stream check the `Authorization: Bearer <device_token>` header. The current implementation records device tokens but does not yet enforce them on every route — this will be tightened in Milestone 3 (auth middleware).

The `/api/setup/token` and `/api/devices/pair/*` endpoints are intentionally unauthenticated to support first-run setup. They should be firewalled or rate-limited in production if the bridge is public.

---

## Transport security

- The bridge must be served over HTTPS in production. The Fly.io deployment enforces this automatically. Self-hosted operators should terminate TLS at a reverse proxy (Caddy auto-TLS recommended).
- The iOS app enforces App Transport Security (ATS). `NSAllowsLocalNetworking` is enabled in Debug builds only to allow simulator testing against `http://localhost`.
- WebSocket connections from the OpenClaw plugin use `wss://` when the bridge URL is `https://`.

---

## Secrets handling

| Secret | Storage |
|---|---|
| Bridge token (raw) | Shown once at generation time, never re-exposed |
| Bridge token (hashed) | SQLite `bridge_tokens.token_hash` |
| Device token | SQLite `device_tokens` table (hashing planned) |
| iOS device token | iOS Keychain (planned; currently `UserDefaults` for prototype) |
| APNs private key | Fly secrets / environment variable — never committed |

**Move iOS device token to Keychain before any TestFlight distribution.**

---

## Data isolation

- One bridge instance serves one user. No multi-tenancy, no cross-user data leakage.
- The SQLite database is the only persistent store. Back it up; there is no cloud sync.
- Agent conversation transcripts remain inside OpenClaw. The bridge stores only a summary (message text, status) for iOS display — it does not receive tool outputs or system-context data unless the OpenClaw agent explicitly includes them in an `outbound.message`.

---

## Known limitations (current milestone)

1. **Device tokens not yet hashed in storage** — raw token in DB; mitigate by restricting DB file permissions (`chmod 600`).
2. **Pairing flow not cryptographically verified** — the `/pair/finish` endpoint currently accepts any code; a real exchange will be added in Milestone 3.
3. **No rate limiting** on the bridge API — add via Fly.io rate limits or a Hono middleware before public exposure.
4. **SSE stream not paginated by token** — any client with a valid device token can read the full event history via `?cursor=`. Acceptable for single-user; revisit if multi-device support is added.

---

## Reporting vulnerabilities

Open a GitHub issue marked **[security]** or email the maintainer directly. Do not post exploit details publicly before a fix is available.
