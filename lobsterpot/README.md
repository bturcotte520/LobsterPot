# LobsterPot

LobsterPot is a native iOS messaging app for OpenClaw. It uses a Telegram-style token flow: users run their own bridge, install the LobsterPot OpenClaw channel plugin, paste the generated config snippet, and OpenClaw connects outbound to the bridge.

The default path does not require OpenClaw Gateway operator credentials.

## Monorepo

- `apps/bridge` - self-hosted bridge for iOS devices and the OpenClaw channel plugin.
- `apps/push-relay` - optional hosted relay for official/TestFlight push notifications.
- `apps/ios` - SwiftUI iOS app source.
- `packages/openclaw-channel` - OpenClaw channel plugin.
- `packages/protocol` - shared bridge/plugin/iOS protocol schemas.
- `packages/shared` - shared Node utilities.

## Local Development

```bash
pnpm install
pnpm build
pnpm test
pnpm dev:bridge
```

Generate a channel token:

```bash
curl -X POST http://127.0.0.1:3000/api/setup/token
```

Then fetch the OpenClaw config snippet:

```bash
curl http://127.0.0.1:3000/api/setup/snippet
```

## Current Status

This repository contains the first production backbone: shared protocol types, bridge scaffolding, token-based plugin connection, plugin package skeleton, push relay skeleton, and iOS source scaffolding.
