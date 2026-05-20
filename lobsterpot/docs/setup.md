# Setup Guide

This guide walks through standing up the LobsterPot bridge, installing the OpenClaw channel plugin, and connecting the iOS app for the first time.

## Prerequisites

| Requirement | Minimum version |
|---|---|
| Node.js | 22 |
| pnpm | 9.15 |
| Docker (local dev) | 24 |
| Fly CLI (cloud deploy) | 0.2 |
| Xcode (iOS build) | 15 |
| XcodeGen | 2.41 |

---

## 1. Clone the repo

```sh
git clone https://github.com/your-org/lobsterpot.git
cd lobsterpot
pnpm install
pnpm build
```

---

## 2. Start the bridge locally

Copy the environment template and fill in values:

```sh
cp .env.example .env
```

Key variables:

| Variable | Description |
|---|---|
| `BRIDGE_PORT` | HTTP port for the bridge (default `3000`) |
| `BRIDGE_PUBLIC_BASE_URL` | Public HTTPS URL (used in config snippets) |
| `BRIDGE_DB_PATH` | SQLite file path (default `./bridge.db`) |

Start with Docker Compose:

```sh
docker compose up bridge
```

Or run directly:

```sh
pnpm dev:bridge
```

The bridge will be available at `http://127.0.0.1:3000`.

### Health check

```sh
curl http://127.0.0.1:3000/healthz
# {"ok":true,"service":"lobsterpot-bridge","now":"..."}
```

---

## 3. Create a bridge token

The OpenClaw plugin authenticates to the bridge with a long-lived token. Generate one:

```sh
curl -X POST http://127.0.0.1:3000/api/setup/token
# {"id":"...","token":"lobsterpot_XXXXXX","createdAt":"..."}
```

Save the `token` value — it is shown only once.

---

## 4. Install the OpenClaw channel plugin

From inside the OpenClaw directory, register the plugin:

```sh
openclaw plugin add /path/to/lobsterpot/packages/openclaw-channel
```

Add the channel configuration to your OpenClaw config (JSON5):

```json5
{
  channels: {
    lobsterpot: {
      enabled: true,
      bridgeUrl: "https://my-bridge.fly.dev",   // or http://127.0.0.1:3000 for local dev
      token: "lobsterpot_XXXXXX",
      dmPolicy: "allowlist",
      allowFrom: ["ios:primary"]
    }
  }
}
```

Restart OpenClaw. The plugin will establish a WebSocket connection to the bridge. Verify with:

```sh
curl http://127.0.0.1:3000/api/status
# {"plugin":{"connected":true,...}}
```

---

## 5. Pair the iOS app

1. Open the LobsterPot app on your device.
2. Enter the bridge URL (e.g. `https://my-bridge.fly.dev`).
3. Tap **Connect** — the app calls `/api/devices/pair/start` and displays a pairing code.
4. Confirm the pairing code in the bridge (future: web UI; for now verify via API).
5. Tap **I've entered the code** — the app exchanges the code for a device token and begins syncing conversations.

---

## 6. Verify end-to-end

1. In the iOS app, tap **+** to create a new conversation.
2. Send a message — it appears immediately in the conversation.
3. Watch for the assistant reply streamed back through the SSE event stream.

---

## iOS build (local)

Install XcodeGen if you haven't:

```sh
brew install xcodegen
```

Generate the Xcode project:

```sh
cd apps/ios
xcodegen generate
open LobsterPot.xcodeproj
```

Build and run on the simulator or a connected device from Xcode.
