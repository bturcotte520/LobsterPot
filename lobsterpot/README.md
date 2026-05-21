# 🦞 LobsterPot

An iMessage-style iOS app for chatting with your [OpenClaw](https://openclaw.ai) agent and its subagents. Each agent session appears as a thread in a familiar messaging UI.

## How it works

LobsterPot connects directly to an OpenClaw Gateway as a `role=operator` client over WebSocket. No middleware, no bridge — just the Gateway's built-in protocol.

```
iPhone  ──── WSS (Tailscale) ────►  OpenClaw Gateway
                                    ├─ main agent session     → inbox row 1
                                    ├─ subagent session A     → inbox row 2
                                    └─ subagent session B     → inbox row 3
```

## Quick start

**Prerequisites:**
- An OpenClaw Gateway running somewhere (local Mac, KiloClaw VPS, etc.)
- iPhone and Gateway on the same Tailscale tailnet (recommended)
- Xcode 16+ + [`xcodegen`](https://github.com/yonaskolb/XcodeGen)

**Build and run:**

```sh
brew install xcodegen        # if not installed
cd apps/ios
xcodegen generate
open LobsterPot.xcodeproj    # hit Run in Xcode
```

**Pair with your Gateway:**

1. Open LobsterPot on your iPhone
2. Enter your Gateway's Tailscale hostname (e.g. `wss://kiloclaw.tail-abc.ts.net:18789`) and the `gateway.auth.token` from `~/.openclaw/openclaw.json`
3. SSH into your Gateway and run:
   ```sh
   openclaw devices list
   openclaw devices approve <request-id>
   ```
4. Your sessions appear in the inbox automatically

## Multi-workspace

Tap your workspace avatar in the top-left corner to add or switch between multiple Gateways (like switching between Slack workspaces).

## Architecture

- **Direct WebSocket** — no bridge or relay required
- **Ed25519 device identity** — keypair generated once, persisted in Keychain
- **Keychain storage** — gateway tokens and device tokens never touch UserDefaults
- **Streaming messages** — protocol v4 delta events rendered in real-time
- **Flat session list** — main agent + all subagents as peers in the inbox

## Development

The pre-pivot branch (`pre-pivot-archive`) preserves the original bridge + channel plugin architecture if you want to reference it.

## License

MIT
