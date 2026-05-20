# Deployment Guide

## Bridge on Fly.io (recommended)

The bridge includes a ready-to-use `fly.toml` at `apps/bridge/fly.toml`.

### First deploy

```sh
# Install flyctl if needed
brew install flyctl
fly auth login

cd apps/bridge
fly launch --no-deploy     # creates the app; edit fly.toml name if needed
fly volumes create lobsterpot_data --size 1 --region iad
fly secrets set BRIDGE_PUBLIC_BASE_URL=https://<your-app>.fly.dev
fly deploy
```

The bridge is deployed with a persistent 1 GB volume mounted at `/data` for SQLite.

### Subsequent deploys

From the monorepo root:

```sh
pnpm build
fly deploy --config apps/bridge/fly.toml
```

### Environment variables on Fly

| Secret | Description |
|---|---|
| `BRIDGE_PUBLIC_BASE_URL` | The app's public HTTPS URL |
| `BRIDGE_DB_PATH` | `/data/bridge.db` (set automatically via fly.toml) |

### Health check

```sh
fly status --app <your-app>
curl https://<your-app>.fly.dev/healthz
```

---

## Bridge with Docker (self-hosted)

```sh
# Build the image
docker build -t lobsterpot-bridge apps/bridge

# Run with a persistent volume
docker run -d \
  --name lobsterpot-bridge \
  -p 3000:3000 \
  -v lobsterpot_data:/data \
  -e BRIDGE_DB_PATH=/data/bridge.db \
  -e BRIDGE_PUBLIC_BASE_URL=https://my-server.example.com \
  lobsterpot-bridge
```

Put a reverse proxy (Caddy, nginx, Traefik) in front to handle TLS.

### Caddy snippet

```
my-server.example.com {
    reverse_proxy localhost:3000
}
```

---

## Push relay (optional)

The push relay is only needed for TestFlight / App Store builds where you want background push notifications. Self-hosted builds can operate without it (SSE provides foreground delivery).

```sh
cd apps/push-relay
fly launch --no-deploy
fly secrets set APNS_KEY_ID=... APNS_TEAM_ID=... APNS_BUNDLE_ID=com.lobsterpot.app
# Add APNS_PRIVATE_KEY as a multiline secret
fly secrets set APNS_PRIVATE_KEY="$(cat AuthKey_XXXXXXXX.p8)"
fly deploy
```

Then set `PUSH_RELAY_URL` on the bridge:

```sh
fly secrets set PUSH_RELAY_URL=https://<your-relay>.fly.dev \
  --app <your-bridge-app>
```

---

## Upgrading

```sh
git pull
pnpm install
pnpm build
fly deploy --config apps/bridge/fly.toml
```

SQLite migrations are applied automatically at bridge startup via the idempotent `0001_initial.sql`.

---

## Backup

The SQLite database is the only stateful artifact:

```sh
fly ssh console --app <your-bridge-app> -C "sqlite3 /data/bridge.db .dump" > backup.sql
```

Or use `fly volumes snapshots create` for a block-level snapshot.
