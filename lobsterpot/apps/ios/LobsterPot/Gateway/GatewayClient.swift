import Foundation

// MARK: - Connection state

enum GatewayConnectionState: Equatable {
    case disconnected
    case connecting
    case waitingForPairing(deviceId: String)
    case connected(serverVersion: String)
    case error(String)
}

// MARK: - GatewayClient errors

enum GatewayClientError: LocalizedError {
    case invalidURL
    case connectFailed(String)
    case rpcFailed(String, String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid gateway URL"
        case .connectFailed(let msg): return "Gateway connect failed: \(msg)"
        case .rpcFailed(let method, let msg): return "\(method) failed: \(msg)"
        case .timeout: return "Request timed out"
        }
    }
}

// MARK: - GatewayClient

/// Manages a single WebSocket connection to an OpenClaw Gateway as `role=operator`.
///
/// Connection lifecycle:
/// 1. `connect()` is called → WS task starts, challenge received
/// 2. Challenge signed → `connect` RPC sent → `hello-ok` or error returned
/// 3. If `PAIRING_REQUIRED`: loop with 5-second delay until approved
/// 4. On `hello-ok`: `deviceToken` persisted to Keychain for future reconnects
/// 5. `sessions.subscribe` issued to receive `sessions.changed` events
@MainActor
final class GatewayClient: NSObject {

    // MARK: - Configuration

    let workspace: Workspace
    let identity: DeviceIdentity

    // MARK: - State

    private(set) var connectionState: GatewayConnectionState = .disconnected {
        didSet { onStateChange?(connectionState) }
    }

    // MARK: - Callbacks (dispatched on MainActor)

    var onStateChange: ((GatewayConnectionState) -> Void)?
    var onSessionsChanged: (() -> Void)?
    var onSessionMessage: ((SessionMessageEventPayload) -> Void)?

    // MARK: - Private

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var pendingRPCs: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextId = 1
    private var connectContinuation: CheckedContinuation<HelloOkPayload, Error>?
    private var challengeContinuation: CheckedContinuation<ConnectChallengePayload, Error>?
    private var receiveLoopTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var shouldReconnect = false
    private var reconnectBackoff: UInt64 = 1_000_000_000  // 1s → 30s

    // MARK: - Init

    init(workspace: Workspace, identity: DeviceIdentity) {
        self.workspace = workspace
        self.identity = identity
    }

    // MARK: - Public API

    func start() {
        shouldReconnect = true
        reconnectBackoff = 1_000_000_000
        startConnection()
    }

    func stop() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        disconnect()
    }

    func sendToSession(_ sessionKey: String, message: String) async throws {
        let params = SessionsSendParams(
            key: sessionKey,
            message: message,
            idempotencyKey: UUID().uuidString
        )
        _ = try await rpc("sessions.send", params: encodeParams(params))
    }

    func listSessions(
        agentId: String? = nil,
        limit: Int = 50,
        includeTitles: Bool = true,
        includeLastMessage: Bool = true
    ) async throws -> [GWSessionRow] {
        let params = SessionsListParams(
            limit: limit,
            agentId: agentId,
            includeDerivedTitles: includeTitles,
            includeLastMessage: includeLastMessage,
            configuredAgentsOnly: true
        )
        let result = try await rpc("sessions.list", params: encodeParams(params))
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let parsed = try? JSONDecoder().decode(SessionsListResult.self, from: data)
        else { return [] }
        return parsed.sessions
    }

    func loadHistory(sessionKey: String, limit: Int = 100) async throws -> [GWChatMessage] {
        let params = ChatHistoryParams(sessionKey: sessionKey, limit: limit)
        let result = try await rpc("chat.history", params: encodeParams(params))
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let parsed = try? JSONDecoder().decode(ChatHistoryResult.self, from: data)
        else { return [] }
        return parsed.messages
    }

    func subscribeMessages(sessionKey: String) async throws {
        let params = SessionsMessagesSubscribeParams(key: sessionKey)
        _ = try await rpc("sessions.messages.subscribe", params: encodeParams(params))
    }

    func unsubscribeMessages(sessionKey: String) async throws {
        let params = SessionsMessagesSubscribeParams(key: sessionKey)
        _ = try await rpc("sessions.messages.unsubscribe", params: encodeParams(params))
    }

    func createSession(agentId: String? = nil, label: String? = nil) async throws -> GWSessionRow? {
        let params = SessionsCreateParams(agentId: agentId, label: label, message: nil)
        let result = try await rpc("sessions.create", params: encodeParams(params))
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let row = try? JSONDecoder().decode(GWSessionRow.self, from: data)
        else { return nil }
        return row
    }

    // MARK: - Private connection management

    private func startConnection() {
        guard shouldReconnect else { return }
        connectionState = .connecting

        reconnectTask = Task { [weak self] in
            await self?.connectionLoop()
        }
    }

    private func connectionLoop() async {
        while shouldReconnect && !Task.isCancelled {
            do {
                try await attemptConnect()
                reconnectBackoff = 1_000_000_000  // reset on success
                // Connection ended cleanly; reconnect if still desired
                if shouldReconnect {
                    connectionState = .connecting
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            } catch is CancellationError {
                break
            } catch let err as GatewayClientError {
                switch err {
                case .connectFailed(let msg) where msg.contains("PAIRING_REQUIRED"):
                    // Keep the waiting-for-pairing state; short retry
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                default:
                    connectionState = .error(err.localizedDescription ?? "Connection failed")
                    try? await Task.sleep(nanoseconds: reconnectBackoff)
                    reconnectBackoff = min(reconnectBackoff * 2, 30_000_000_000)
                }
            } catch {
                connectionState = .error(error.localizedDescription)
                try? await Task.sleep(nanoseconds: reconnectBackoff)
                reconnectBackoff = min(reconnectBackoff * 2, 30_000_000_000)
            }
        }
    }

    private func attemptConnect() async throws {
        guard let url = buildWebSocketURL() else { throw GatewayClientError.invalidURL }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config)
        let wsTask = session.webSocketTask(with: url)
        urlSession = session
        task = wsTask
        wsTask.resume()

        // Start receive loop
        receiveLoopTask?.cancel()
        let receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
        receiveLoopTask = receiveTask

        // Wait for challenge
        let challenge = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<ConnectChallengePayload, Error>) in
            challengeContinuation = cont
        }

        // Build and send connect request
        let connectPayload = buildConnectParams(nonce: challenge.nonce)
        let reqId = makeRequestId()
        let req = GFRequest(id: reqId, method: "connect", params: encodeParams(connectPayload))
        try await send(req)

        // Wait for hello-ok response
        let helloOk = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HelloOkPayload, Error>) in
            connectContinuation = cont
        }

        // Persist device token
        if let token = helloOk.auth.deviceToken, !token.isEmpty {
            workspace.saveDeviceToken(token)
        }

        connectionState = .connected(serverVersion: helloOk.server.version)

        // Subscribe to sessions.changed
        _ = try? await rpc("sessions.subscribe", params: [:])

        // Notify upstream to refresh sessions
        onSessionsChanged?()

        // Keep alive: the receive loop handles the rest
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Wait until the task finishes (disconnect, error, etc.)
            Task {
                receiveTask.value
                cont.resume()
            }
        }
    }

    private func receiveLoop() async {
        guard let wsTask = task else { return }
        while !Task.isCancelled {
            do {
                let message = try await wsTask.receive()
                switch message {
                case .string(let text):
                    handleRawFrame(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        handleRawFrame(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                // Task finished or error; exit loop
                break
            }
        }
        // Notify pending continuations of disconnect
        let err = GatewayClientError.connectFailed("WebSocket disconnected")
        challengeContinuation?.resume(throwing: err)
        challengeContinuation = nil
        connectContinuation?.resume(throwing: err)
        connectContinuation = nil
        for cont in pendingRPCs.values {
            cont.resume(throwing: err)
        }
        pendingRPCs.removeAll()
        if connectionState != .disconnected {
            connectionState = .disconnected
        }
    }

    private func disconnect() {
        receiveLoopTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        connectionState = .disconnected
    }

    // MARK: - Frame handling

    private func handleRawFrame(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }

        // Detect frame type
        guard let typeObj = try? JSONDecoder().decode(GFFrameType.self, from: data) else { return }

        switch typeObj.type {
        case "event":
            handleEventFrame(data)
        case "res":
            handleResponseFrame(data)
        default:
            break
        }
    }

    private func handleEventFrame(_ data: Data) {
        guard let event = try? JSONDecoder().decode(GFEvent.self, from: data) else { return }

        switch event.event {
        case "connect.challenge":
            if let payload = event.payload?.decoded(ConnectChallengePayload.self) {
                challengeContinuation?.resume(returning: payload)
                challengeContinuation = nil
            }

        case "sessions.changed":
            onSessionsChanged?()

        case "session.message":
            if let payload = event.payload?.decoded(SessionMessageEventPayload.self) {
                onSessionMessage?(payload)
            }

        case "tick":
            break  // keepalive, ignore

        default:
            break
        }
    }

    private func handleResponseFrame(_ data: Data) {
        guard let response = try? JSONDecoder().decode(GFResponse.self, from: data) else { return }

        // Check if this is the connect response
        if let cont = connectContinuation {
            if response.ok {
                if let payload = response.payload?.decoded(HelloOkPayload.self) {
                    cont.resume(returning: payload)
                    connectContinuation = nil
                    return
                }
            } else if let error = response.error {
                let code = error.code
                let details = error.details
                if code == "PAIRING_REQUIRED" {
                    connectionState = .waitingForPairing(deviceId: identity.id)
                    // Resume connect continuation with a retriable error
                    cont.resume(throwing: GatewayClientError.connectFailed("PAIRING_REQUIRED:\(identity.id)"))
                    connectContinuation = nil
                } else if code == "AUTH_TOKEN_MISMATCH",
                          details?.canRetryWithDeviceToken == true,
                          let token = workspace.loadDeviceToken()
                {
                    // One-shot retry with device token — handled by retrying attemptConnect
                    cont.resume(throwing: GatewayClientError.connectFailed("AUTH_TOKEN_MISMATCH"))
                    connectContinuation = nil
                } else {
                    cont.resume(throwing: GatewayClientError.connectFailed(error.message))
                    connectContinuation = nil
                }
                return
            }
        }

        // Pending RPC response
        if let cont = pendingRPCs.removeValue(forKey: response.id) {
            if response.ok {
                let dict = (response.payload?.value as? [String: Any]) ?? [:]
                cont.resume(returning: dict)
            } else if let error = response.error {
                cont.resume(throwing: GatewayClientError.rpcFailed("rpc", error.message))
            } else {
                cont.resume(returning: [:])
            }
        }
    }

    // MARK: - RPC helper

    private func rpc(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        guard case .connected = connectionState else {
            throw GatewayClientError.connectFailed("Not connected")
        }
        let reqId = makeRequestId()
        let req = GFRequest(id: reqId, method: method, params: params)
        try await send(req)
        return try await withCheckedThrowingContinuation { cont in
            pendingRPCs[reqId] = cont
        }
    }

    // MARK: - Connect params builder

    private func buildConnectParams(nonce: String) -> ConnectParams {
        let token = workspace.loadDeviceToken() ?? workspace.gatewayToken
        let role = "operator"
        let scopes = ["operator.read", "operator.write"]

        let (sig, signedAt) = identity.sign(
            nonce: nonce,
            role: role,
            scopes: scopes,
            token: token
        )

        let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"

        return ConnectParams(
            client: ConnectClientInfo(
                id: "lobsterpot-ios",
                version: appVersion,
                platform: "ios",
                deviceFamily: "iPhone",
                mode: "operator",
                displayName: workspace.name
            ),
            role: role,
            scopes: scopes,
            caps: nil,
            commands: nil,
            device: DeviceConnectParams(
                id: identity.id,
                publicKey: identity.publicKeyBase64,
                signature: sig,
                signedAt: signedAt,
                nonce: nonce
            ),
            auth: ConnectAuth(
                token: workspace.loadDeviceToken() == nil ? workspace.gatewayToken : nil,
                deviceToken: workspace.loadDeviceToken()
            ),
            locale: Locale.current.identifier,
            userAgent: "LobsterPot-iOS/\(appVersion)"
        )
    }

    // MARK: - Helpers

    private func buildWebSocketURL() -> URL? {
        guard var components = URLComponents(string: workspace.gatewayUrl) else { return nil }
        // Normalise scheme: ws/wss expected; accept http/https and upgrade
        switch components.scheme {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        default: break
        }
        if components.port == nil { components.port = 18789 }
        return components.url
    }

    private func makeRequestId() -> String {
        let id = "lp-\(nextId)"
        nextId += 1
        return id
    }

    private func send<T: Encodable>(_ value: T) async throws {
        guard let wsTask = task else { throw GatewayClientError.connectFailed("No WebSocket task") }
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else { return }
        try await wsTask.send(.string(text))
    }

    private func encodeParams<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }
}

// MARK: - Workspace token helpers (extension)

extension Workspace {
    func loadDeviceToken() -> String? {
        KeychainHelper.load(service: "com.lobsterpot.app", account: "workspace-\(id)")
    }

    func saveDeviceToken(_ token: String) {
        KeychainHelper.save(token, service: "com.lobsterpot.app", account: "workspace-\(id)")
    }

    func deleteDeviceToken() {
        KeychainHelper.delete(service: "com.lobsterpot.app", account: "workspace-\(id)")
    }
}
