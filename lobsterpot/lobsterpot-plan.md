# LobsterPot — iOS Messaging App for OpenClaw

## Vision

An iMessage-style iOS app that connects directly to one or more OpenClaw Gateways as a first-class operator client. Each Gateway is a "workspace" (Slack-style switcher). Each agent session inside that Gateway — main agent session, subagent sessions — is one row in the iMessage inbox. Conversations are tunneled over the Gateway WebSocket using the OpenClaw protocol.

## Architecture

```
iOS app  ──── WSS (Tailscale / direct) ────►  OpenClaw Gateway (port 18789)
                                              ├─ agent:main:main  (row 1)
                                              ├─ agent:main:subagent:<uuid>  (row 2)
                                              └─ agent:main:subagent:<uuid>  (row 3)
```

**No bridge. No relay. No channel plugin.** The iOS app connects as `role=operator` directly to the Gateway WebSocket, uses `sessions.list` to enumerate sessions, and `sessions.send` + `sessions.messages.subscribe` to chat.

## What this replaces

The previous design (bridge + OpenClaw channel plugin + push relay) was a full middleware layer between iOS and OpenClaw. OpenClaw already has everything we need as first-class features: device pairing, sessions, the WebSocket operator protocol, push relay for official builds, Bonjour discovery, TLS pinning. We were re-implementing all of it.

## Protocol

OpenClaw Gateway WebSocket protocol v4. All frames are JSON text messages.

### Frame types
```
Outbound: { type: "req", id, method, params? }
Inbound:  { type: "res", id, ok, payload?, error? }
Inbound:  { type: "event", event, payload?, seq? }
```

### Handshake sequence
1. Gateway sends `event: "connect.challenge"` with `{ nonce, ts }` immediately on connect
2. App sends `method: "connect"` request with:
   - `minProtocol: 3, maxProtocol: 4`
   - `client: { id: "lobsterpot-ios", version, platform: "ios", deviceFamily: "iPhone", mode: "operator" }`
   - `role: "operator"`, `scopes: ["operator.read", "operator.write"]`
   - `device: { id, publicKey, signature, signedAt, nonce }` — Ed25519 identity
   - `auth: { token }` — gateway shared token (first time) or `deviceToken` (reconnects)
3. Gateway responds with `hello-ok` payload including `auth.deviceToken`; app persists token to Keychain
4. If `PAIRING_REQUIRED` with `recommendedNextStep: "wait_then_retry"`: show pairing instructions, loop

### Device signature (v3 payload)
```
v3|{deviceId}|{clientId}|{clientMode}|{role}|{scopes,comma}|{signedAtMs}|{token}|{nonce}|{platform_lower}|{deviceFamily_lower}
```
Signed with Ed25519. `deviceId` = SHA-256 hex of Curve25519 public key raw bytes.
Source: `src/gateway/device-auth.ts` in the OpenClaw repo.

### Key RPCs used by LobsterPot
| RPC | Purpose |
|-----|---------|
| `sessions.list` | Enumerate all sessions (main + subagents) |
| `sessions.subscribe` | Get `sessions.changed` events |
| `sessions.messages.subscribe` | Stream `session.message` events for a session |
| `sessions.messages.unsubscribe` | Unsubscribe from a session |
| `sessions.send` | Send a message to a session |
| `sessions.create` | Create a new session |
| `chat.history` | Get display-normalized message history |

## Repository Structure

```
lobsterpot/
├─ apps/
│   └─ ios/
│       ├─ LobsterPot/               — Swift sources
│       │   ├─ Gateway/
│       │   │   ├─ DeviceIdentity.swift   — Ed25519 keypair + v3 signing
│       │   │   ├─ GatewayClient.swift    — WS client, handshake, RPCs, reconnect
│       │   │   └─ GatewayFrames.swift    — Codable protocol types
│       │   ├─ Workspace/
│       │   │   ├─ Workspace.swift        — Workspace model
│       │   │   └─ WorkspaceStore.swift   — Persistence (UserDefaults + Keychain)
│       │   ├─ App/
│       │   │   ├─ LobsterPotApp.swift
│       │   │   ├─ AppState.swift         — @MainActor ObservableObject
│       │   │   ├─ Models.swift           — Session, Message types
│       │   │   └─ KeychainHelper.swift
│       │   └─ Views/
│       │       ├─ ContentView.swift
│       │       ├─ WorkspacePickerView.swift
│       │       ├─ ConversationListView.swift
│       │       ├─ ChatView.swift
│       │       ├─ SetupView.swift
│       │       └─ SettingsView.swift
│       ├─ LobsterPotTests/
│       └─ project.yml
├─ docs/
│   ├─ getting-started.md
│   ├─ multi-workspace.md
│   └─ tailscale-setup.md
├─ lobsterpot-plan.md
├─ README.md
└─ LICENSE
```

## Multi-workspace (Slack-style)

- Each "workspace" = one paired OpenClaw Gateway
- Workspaces stored in UserDefaults (non-secret: id, name, URL)
- Per-workspace `deviceToken` stored in Keychain under `"workspace-{id}"`
- iOS nav bar: workspace avatar/name → tap to open `WorkspacePickerView`
- Add workspace: enter URL + gateway token → pair flow

## Pairing flow

1. User adds a workspace with the Gateway URL (`wss://hostname:18789`) and gateway shared token
2. App connects, receives `PAIRING_REQUIRED`
3. App shows:
   - `Device ID: {hex}` (for `openclaw devices approve`)
   - Instructions: "SSH into your gateway and run: `openclaw devices approve <id>`"
   - Spinner while retrying every 5 seconds
4. User approves on gateway; next retry succeeds with `hello-ok`
5. `deviceToken` persisted to Keychain; workspace marked paired

## iMessage inbox rows

Each `SessionRow` from `sessions.list` becomes one row:
- Session key `agent:main:main` → labeled "Main" with primary agent icon
- Session key `agent:main:subagent:<uuid>` → label from `sessions.list` derivedTitle or uuid prefix
- Last message preview from `includeLastMessage: true` on list call
- Tap → opens `ChatView` subscribed to that session key

## Streaming messages

1. `ChatView` appears → call `sessions.messages.subscribe` for the session key
2. Gateway sends `session.message` events with `{ sessionKey, role, text, deltaText?, replace? }`
3. In protocol v4: `deltaText` = incremental chunk, `replace=true` = replace last assistant message
4. `ChatView` renders streaming text in-place (partial bubble that updates)
5. `ChatView` disappears / session changes → call `sessions.messages.unsubscribe`

## Push notifications

For dev/local builds: no push needed. App stays connected via WebSocket in foreground.

For TestFlight/production (future): OpenClaw has a relay-based APNs system that requires App Attest + StoreKit JWS. This is separate infrastructure. Not in scope for v1.

## Progress

### Done (to archive in pre-pivot branch)
- Full bridge + PKCE pairing + rate limiting + push relay (deprecated by this pivot)
- OpenClaw channel plugin (deprecated)
- iOS shell UI (partially reusable)

### In Progress
- Pivot to direct OpenClaw node client

### Blocked
- Apple Developer Team ID needed for Xcode signing (`DEVELOPMENT_TEAM` in project.yml)
- Bundle ID: placeholder `com.lobsterpot.app` (confirm or replace)

## Connection to KiloClaw

KiloClaw is an OpenClaw Gateway running on a VPS. Connection via Tailscale:

1. iPhone joins the same Tailscale tailnet as the KiloClaw VPS
2. In LobsterPot: Add Workspace → URL = `wss://<kiloclaw-tailnet-hostname>:18789`
3. Gateway token = value of `gateway.auth.token` in `~/.openclaw/openclaw.json` on the VPS
4. SSH to VPS, run `openclaw devices approve <device-id-shown-in-app>`
5. Done — inbox populates with your agent sessions

## Key Decisions

- **role=operator** for v1 (not role=node): operator scope gives access to all session/chat RPCs. Node capabilities (camera, canvas, etc.) can be added in a future iteration.
- **Flat session list**: all sessions (main + subagents) appear as peers in the iMessage inbox, not hierarchically nested. This matches how iMessage works and is the simplest UX.
- **Single WS connection per workspace**: one `role=operator` connection per workspace. No second node connection needed for v1.
- **Keychain for tokens**: gateway token (shared secret) and device token (long-lived credential) stored under `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- **Ed25519 via CryptoKit**: `Curve25519.Signing.PrivateKey` stored as 32-byte raw representation in Keychain. Public key fingerprint = SHA-256 hex of raw public key bytes = device ID.
