# KiloChat — iOS Subagent Messaging App
## End-to-End Build Plan

---

## Architecture Overview

```
┌──────────────┐         ┌──────────────────┐         ┌───────────────┐
│  iOS App     │◄───────►│  Bridge Service  │◄───────►│  OpenClaw     │
│  (SwiftUI)   │  HTTPS  │  (Node.js/Fly)   │  HTTP   │  Gateway      │
│              │         │  + SQLite        │         │               │
│ Conversations│         │  - routes msgs   │         │  Main session │
│ Main agent   │         │  - stores convos │         │  Subagent     │
│ Subagent A   │         │  - push notifs   │         │  sessions     │
│ Subagent B   │         │  - manages keys  │         │               │
└──────────────┘         └──────────────────┘         └───────────────┘
```

**Key principle:** OpenClaw does agent work. Bridge service does everything else (routing, storage, delivery, push). iOS app does UI.

---

## Core Design Decisions

### 1. Session-per-Conversation Mapping
Each conversation in the app maps to ONE OpenClaw session.

| App Conversation | OpenClaw Session |
|---|---|
| Main Agent (pinned) | Main session (always exists) |
| "Research Bot" | `sessions_spawn(mode="session", label="research-bot")` |
| "Code Reviewer" | `sessions_spawn(mode="session", label="code-reviewer")` |
| "Travel Planner" | `sessions_spawn(mode="session", label="travel-planner")` |

The bridge service stores this mapping: `conversation_id → openclaw_session_key`

### 2. Message Routing
```
User sends msg in "Research Bot" conversation
  → iOS app POSTs to bridge: { conversation_id, message }
  → Bridge looks up openclaw_session_key
  → Bridge POSTs to OpenClaw: sessions_send(session_key, message)
  → OpenClaw responds
  → Bridge pushes response to iOS via WebSocket / SSE
```

### 3. New Subagent Creation
```
User taps "New Conversation" → enters name + purpose
  → iOS POSTs to bridge: { name, purpose }
  → Bridge calls OpenClaw:
      sessions_spawn(
        task="You are {name}. {purpose}. Stay in character.",
        mode="session",
        label="{slugified-name}"
      )
  → OpenClaw returns session_key
  → Bridge stores mapping, returns conversation to iOS
```

### 4. Token Efficiency
- **No context fork:** Subagents are isolated. No transcript sharing unless explicitly requested.
- **System prompt only:** Each subagent gets a 1-paragraph system prompt (name + purpose). Nothing else.
- **No DB round-trips for agent context:** System prompt is baked into the spawn task, not fetched per-message.
- **Main agent is the only "smart" one:** Subagents are dumb specialists. Main agent handles routing, planning, complex reasoning.
- **Message history stored in SQLite, not in agent context:** The agent sees only the current turn (standard OpenClaw behavior).

### 5. No Tangle Guarantee
- Each conversation has a unique `conversation_id` (UUID).
- Bridge service maps `conversation_id → session_key` 1:1.
- The bridge NEVER mixes messages between conversations.
- The main agent session handles ONLY the pinned conversation.
- Subagent sessions handle ONLY their mapped conversation.
- No shared state between subagents.

---

## Tech Stack

| Layer | Technology | Why |
|---|---|---|
| iOS App | Swift + SwiftUI | Native, best UX, built-in autocorrect/scribble |
| Backend | Node.js (TypeScript) + Hono | Lightweight, same ecosystem as OpenClaw |
| Database | SQLite (better-sqlite3) | Zero-config, single file, perfect for single-user |
| Hosting | Fly.io | Where OpenClaw already runs, cheap |
| Push | APNs (Apple Push Notification service) | Native iOS push |
| Realtime | Server-Sent Events (SSE) | Simpler than WebSockets, sufficient for chat |
| Auth | HMAC-signed tokens | Same pattern OpenClaw uses |

---

## Phase-by-Phase Build Plan

### Phase 1: Bridge Service (Backend)

**What to build:**
1. Express/Hono server with these endpoints:
   - `POST /messages` — receive message from iOS, route to OpenClaw
   - `GET /messages/stream` — SSE stream for realtime responses
   - `POST /conversations` — create new subagent conversation
   - `GET /conversations` — list all conversations
   - `POST /auth` — authenticate with OpenClaw token

2. SQLite schema:
```sql
CREATE TABLE conversations (
  id TEXT PRIMARY KEY,        -- UUID
  name TEXT NOT NULL,
  purpose TEXT,
  session_key TEXT,           -- OpenClaw session key
  is_main INTEGER DEFAULT 0,  -- 1 for main agent conversation
  created_at TEXT DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT REFERENCES conversations(id),
  role TEXT NOT NULL,         -- 'user' or 'assistant'
  content TEXT NOT NULL,
  created_at TEXT DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE openclaw_config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
-- Store: gateway_url, gateway_token, session_key_main
```

3. OpenClaw integration:
   - On first setup: user provides OpenClaw gateway URL + token
   - Bridge stores these in SQLite
   - Bridge creates the main conversation (pinned)
   - All API calls to OpenClaw use the gateway HTTP API

---

### Phase 2: OpenClaw Integration

**What OpenClaw needs to do:**

The bridge service calls OpenClaw's existing APIs:
- `sessions_send(session_key, message)` — send message to any session
- `sessions_spawn(task, mode="session")` — create new subagent session
- `sessions_list()` — list existing sessions
- `sessions_history(session_key)` — get conversation history (for scrollback)

**Custom OpenClaw channel (optional but recommended):**

Instead of the bridge polling OpenClaw, create a minimal custom channel plugin that:
1. Receives messages from the bridge
2. Routes them to the correct session
3. Pushes responses back to the bridge

This is cleaner than the bridge calling `sessions_send` and waiting for a response. The flow:

```
iOS → Bridge → OpenClaw custom channel → correct session → response → channel → Bridge → iOS
```

---

### Phase 3: iOS App

**Screens:**
1. **Conversation List** — main screen, shows all conversations
   - Pinned top: Main Agent (with your avatar)
   - Below: all subagent conversations
   - Each row: avatar, name, last message preview, timestamp, unread count
   - Swipe to delete archive

2. **Conversation View** — chat screen
   - Message bubbles (user right, assistant left)
   - Typing indicator
   - Text input with autocorrect, dictation, scribble support
   - Edit sent messages (long press)
   - Swipe to reply to specific message

3. **New Conversation** — modal sheet
   - Name field
   - Purpose/description field
   - Create button → spawns subagent via bridge

4. **Settings**
   - OpenClaw gateway URL
   - Token
   - Push notification toggle

**iOS-specific features to include:**
- `TextEditor` with autocorrect (built into SwiftUI `TextField`)
- Scribble support (automatic for iPad, limited on iPhone)
- Haptic feedback on send
- Dark mode
- Pull to refresh
- Background fetch for new messages
- Local notifications for push

---

## AI Agent Prompts

### Prompt 1: Scaffold the Backend

```
Build a Node.js bridge service for connecting an iOS app to an OpenClaw instance.

Tech: TypeScript, Hono (web framework), better-sqlite3, Node.js 20+

Requirements:
1. SQLite database with these tables:
   - conversations (id, name, purpose, session_key, is_main, created_at, updated_at)
   - messages (id, conversation_id, role, content, created_at)
   - openclaw_config (key, value)

2. API endpoints:
   - POST /api/setup — store OpenClaw gateway URL and token
   - POST /api/conversations — create new subagent (calls OpenClaw sessions_spawn)
   - GET /api/conversations — list all conversations (sorted by updated_at desc)
   - POST /api/messages — send message to a conversation (calls OpenClaw sessions_send)
   - GET /api/messages/:conversation_id — get message history for a conversation
   - GET /api/stream — SSE endpoint for realtime responses

3. OpenClaw integration:
   - Use HTTP calls to the OpenClaw gateway API
   - sessions_send for sending messages
   - sessions_spawn for creating subagents
   - Parse the gateway API responses and relay back to the client

4. Auth: Simple token auth. The iOS app sends a Bearer token matching the one stored in openclaw_config.

5. Error handling: graceful failures, proper HTTP status codes, no crashes.

Structure:
  /src/
    index.ts          — Hono app, routes
    db.ts             — SQLite setup, queries
    openclaw.ts       — OpenClaw API client
    types.ts          — TypeScript types
  /package.json
  /tsconfig.json

Start with the package.json, tsconfig, and database schema. Then build each layer.
Test with curl commands after each endpoint.
```

### Prompt 2: OpenClaw Session Management

```
Build the OpenClaw integration layer for the bridge service.

The bridge needs to:
1. Create subagent sessions: Call POST to OpenClaw gateway with sessions_spawn
   - task: system prompt combining name + purpose
   - mode: "session" (persistent)
   - Return the session_key to store in the database

2. Send messages: Call POST to OpenClaw gateway with sessions_send
   - session_key: from the database
   - message: user's message text
   - Wait for response (OpenClaw returns the assistant reply)
   - Store the response in the messages table

3. List sessions: Call GET to OpenClaw gateway to see active sessions
   - Use this to detect stale sessions and handle cleanup

The OpenClaw gateway API is at {GATEWAY_URL}/api/sessions/
Auth header: Authorization: Bearer {GATEWAY_TOKEN}

Create src/openclaw.ts with these functions:
- setupClient(gatewayUrl, gatewayToken)
- createSubagent(name: string, purpose: string) → { sessionKey: string }
- sendMessage(sessionKey: string, message: string) → { reply: string }
- listSessions() → Session[]
- getSessionHistory(sessionKey: string) → Message[]

Handle errors: timeouts, connection refused, invalid token.
Use fetch with AbortController for timeout (30s default).
```

### Prompt 3: iOS App — Setup & Conversation List

```
Build a SwiftUI iOS app called "KiloChat" — a messaging app for chatting with an OpenClaw agent and its subagents.

Use Swift 5.9+, SwiftUI, Xcode 15+.

Phase 1: Setup screen + conversation list

1. SetupScreen (shown on first launch):
   - "Connect to OpenClaw" header
   - Gateway URL text field
   - Token text field (secure)
   - "Connect" button
   - On success: save to UserDefaults (secure enclave for token), show ConversationList

2. ConversationList:
   - NavigationStack
   - Pinned row at top: "Main Agent" with a robot icon
   - Below: list of subagent conversations from the API
   - Each row: name, last message preview, time, unread badge
   - Pull to refresh
   - "New Conversation" button (trailing nav bar)
   - Tap a row → navigate to ChatView (stub for now)

3. NewConversationSheet:
   - Modal sheet with:
     - Name text field
     - Purpose text field (multi-line)
     - "Create" button → calls POST /api/conversations, refreshes list, dismisses

API calls go to a configurable base URL stored in UserDefaults.
Use async/await for all network calls.
Use a simple ObservableObject for the app state.

Make it look clean and minimal — Apple-style design, no heavy theming.
System fonts, standard spacing, light/dark mode support.
```

### Prompt 4: iOS App — Chat View

```
Build the ChatView for KiloChat.

Requirements:
1. Message list:
   - ScrollView with message bubbles
   - User messages: right-aligned, blue background
   - Assistant messages: left-aligned, gray background
   - Timestamps below each message
   - Typing indicator (animated dots) when waiting for response

2. Text input:
   - TextField at bottom with autocorrect enabled
   - Send button (disabled when empty)
   - Supports dictation (Siri button on keyboard)
   - Long press on sent message → edit option
   - Swipe right on message → reply to (quote the message above input)

3. Behavior:
   - On send: POST to /api/messages, then listen to SSE /api/stream for response
   - Display incoming response in real-time (streaming if possible)
   - Auto-scroll to bottom on new messages
   - Pull down to load older messages (pagination)

4. Navigation:
   - Back button to conversation list
   - Title = conversation name
   - Info button (trailing) → conversation details

Use Message model: { id, role, content, createdAt }
Use SSE for streaming responses. Handle reconnection gracefully.
```

### Prompt 5: Deploy to Fly.io

```
The bridge service needs to be deployed to Fly.io.

1. Create a Dockerfile:
   - Node.js 20 slim base
   - Copy built JS files
   - Expose port 3000
   - Run: node dist/index.js

2. Create fly.toml:
   - app name: kilochat-bridge
   - port: 3000
   - internal port: 3000
   - volume for SQLite data (persist across restarts)
   - secrets for OPENCLAW_GATEWAY_TOKEN

3. Deploy commands:
   - fly launch
   - fly volumes create sqlite_data --size 1
   - fly secrets set OPENCLAW_GATEWAY_TOKEN={token}
   - fly deploy

4. Post-deploy:
   - The iOS app connects to https://kilochat-bridge.fly.dev
   - First-run setup stores the URL and token
```

---

## Data Flow — Complete Example

```
1. User opens app → sees conversation list
   Bridge: GET /api/conversations → returns [{id, name, lastMessage, ...}]

2. User taps "Research Bot"
   Bridge: GET /api/messages/{conversation_id} → returns message history

3. User types "What's the latest on RAG benchmarks?" → sends
   Bridge: POST /api/messages { conversation_id, message }
   → Bridge looks up session_key for this conversation
   → Bridge calls OpenClaw: sessions_send(session_key, message)
   → OpenClaw's subagent processes, returns reply
   → Bridge stores message + reply in SQLite
   → Bridge pushes reply to iOS via SSE

4. User taps "New Conversation"
   → Types name: "Code Reviewer", purpose: "Reviews my PRs for bugs and style"
   Bridge: POST /api/conversations { name, purpose }
   → Bridge calls OpenClaw: sessions_spawn(task="You are Code Reviewer. Reviews PRs for bugs and style.", mode="session")
   → OpenClaw returns session_key
   → Bridge stores conversation + session_key mapping
   → Bridge returns new conversation to iOS
   → iOS shows it in the list

5. User switches back to "Research Bot"
   → Same session_key, same context, no re-spawn needed
   → Subagent remembers everything from previous messages in its session
```

---

## Key OpenClaw API Calls

All via HTTP to `{gateway_url}/api/`:

```
# Create subagent session
POST /api/sessions/spawn
Headers: Authorization: Bearer {gateway_token}
Body: {
  "task": "You are {name}. {purpose}.",
  "mode": "session",
  "label": "{slug}",
  "runtime": "subagent"
}
Response: { "sessionKey": "..." }

# Send message to existing session
POST /api/sessions/send
Headers: Authorization: Bearer {gateway_token}
Body: {
  "sessionKey": "...",
  "message": "What's the latest on RAG benchmarks?"
}
Response: { "reply": "..." }

# List sessions
GET /api/sessions
Headers: Authorization: Bearer {gateway_token}
```

---

## Token Cost Analysis

| Operation | Approx Token Cost | Notes |
|---|---|---|
| Spawn subagent | ~200 input tokens | System prompt only |
| Send message (per turn) | User msg + response | Standard OpenClaw cost |
| No context inflation | — | No fork, no history injection |
| Session persistence | — | OpenClaw manages session history |

**Estimated per-message cost:** Same as a normal OpenClaw conversation. No overhead from the bridge or app.

---

## Order of Operations

1. **Backend first** — Bridge service with SQLite + OpenClaw integration
2. **Test with curl** — Verify all endpoints work against your OpenClaw instance
3. **iOS app skeleton** — Xcode project, SwiftUI views, API client
4. **Connect iOS → Bridge → OpenClaw** — End-to-end message flow
5. **Polish** — Typing indicators, streaming, push notifications, editing
6. **Deploy bridge** — Fly.io with persistent SQLite volume
7. **Ship** — TestFlight for personal use

---

## What NOT to Do

- ❌ Don't use a shared database for agent context — keep context in OpenClaw sessions
- ❌ Don't fork context to subagents — isolated is cheaper and cleaner
- ❌ Don't build your own agent framework — OpenClaw handles sessions, routing, tools
- ❌ Don't use React Native — SwiftUI is better for this use case and you're building for one platform
- ❌ Don't over-engineer auth — it's for personal use, HMAC tokens are enough
- ❌ Don't build message sync across devices — single user, single device to start

---

## Files to Create

```
kilochat/
├── backend/
│   ├── package.json
│   ├── tsconfig.json
│   ├── src/
│   │   ├── index.ts          # Hono app + routes
│   │   ├── db.ts             # SQLite setup + queries
│   │   ├── openclaw.ts       # OpenClaw API client
│   │   └── types.ts          # Shared types
│   ├── Dockerfile
│   └── fly.toml
├── ios/
│   ├── KiloChat.xcodeproj/
│   └── KiloChat/
│       ├── KiloChatApp.swift
│       ├── Models/
│       │   ├── Conversation.swift
│       │   └── Message.swift
│       ├── Services/
│       │   ├── APIClient.swift
│       │   └── SSEClient.swift
│       ├── Views/
│       │   ├── SetupView.swift
│       │   ├── ConversationListView.swift
│       │   ├── ChatView.swift
│       │   └── NewConversationSheet.swift
│       └── AppState.swift
└── README.md
```

---

## Next Steps

1. Clone this plan
2. Start with **Prompt 1** (backend scaffold) in your AI coding agent
3. Test backend endpoints with curl against your OpenClaw instance
4. Move to **Prompt 3** (iOS app) once backend works
5. Deploy to Fly.io when everything is functional
