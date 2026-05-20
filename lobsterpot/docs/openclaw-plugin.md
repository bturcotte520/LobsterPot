# OpenClaw Channel Plugin

The `@lobsterpot/openclaw-channel` package is an OpenClaw native channel plugin. It connects your OpenClaw instance outbound to the LobsterPot bridge over a persistent WebSocket, so no inbound firewall rules or public OpenClaw URL is required.

## Architecture

```
iOS App  ←──── HTTPS/SSE ────→  Bridge  ←──── WebSocket (outbound) ────→  OpenClaw Plugin
```

The plugin initiates the connection; the bridge never needs to reach into OpenClaw.

## Installation

```sh
# From the monorepo root after pnpm build
openclaw plugin add ./packages/openclaw-channel

# Or install from a published path / npm package
openclaw plugin add @lobsterpot/openclaw-channel
```

## Configuration

Add a `channels.lobsterpot` block to your OpenClaw config:

```json5
{
  channels: {
    lobsterpot: {
      // Required
      enabled: true,
      bridgeUrl: "https://my-bridge.fly.dev",
      token: "lobsterpot_XXXXXX",

      // Optional — who can send messages to the agent
      dmPolicy: "allowlist",          // "open" | "allowlist"
      allowFrom: ["ios:primary"],     // sender IDs allowed when dmPolicy = "allowlist"

      // Optional — retry tuning
      reconnectDelayMs: 2000,         // base backoff for reconnects (default 2000)
      maxReconnectDelayMs: 30000      // cap (default 30000)
    }
  }
}
```

## Token management

Tokens are generated on the bridge:

```sh
curl -X POST https://my-bridge.fly.dev/api/setup/token
# {"id":"...","token":"lobsterpot_XXXXXX","createdAt":"..."}
```

The token is stored as a SHA-256 hash in the bridge database. If a token is compromised, revoke it by deleting the row from `bridge_tokens` and generating a new one.

## Protocol overview

When OpenClaw starts the plugin:

1. Plugin opens a WebSocket to `wss://<bridgeUrl>/api/openclaw/connect`.
2. Plugin sends a `hello` frame with the token, instance ID, and capabilities.
3. Bridge validates the token hash and replies with `hello.ok` (or `hello.error`).
4. Plugin maintains the connection with `presence.heartbeat` pings every 25 s.
5. Bridge forwards iOS user messages as `inbound.message` frames.
6. OpenClaw processes the message and the plugin sends back `outbound.message` (streaming) and `outbound.message` (final) frames.
7. If the agent requests human approval, the plugin sends `outbound.approval.requested`; the iOS user responds and the bridge delivers `inbound.approval.respond`.

All frames are JSON-serialized. The schema is defined in `packages/protocol/src/index.ts` and versioned with `LOBSTERPOT_PROTOCOL_VERSION`.

## Capabilities

Declare capabilities in the config to enable optional bridge features:

| Capability | Description |
|---|---|
| `text` | Plain text messages (baseline, always supported) |
| `progress` | `outbound.progress` frames for tool-use status |
| `approvals` | `outbound.approval.requested` frames |
| `streaming` | Incremental `outbound.message` frames with `status: "streaming"` |

## Reconnection behaviour

The plugin uses exponential backoff capped at `maxReconnectDelayMs`. On reconnect it sends the last known `resumeCursor` in the `hello` frame; the bridge uses this to replay any events the plugin missed while disconnected.

## OpenClaw version compatibility

The plugin declares a peer dependency of `openclaw >= 2026.0.0`. The channel plugin API (`openclaw.plugin.json` manifest + channel runtime) was introduced in that release. Confirm the target version with your OpenClaw instance before deploying.
