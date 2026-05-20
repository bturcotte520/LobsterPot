import Foundation

/// HTTP + SSE client for the LobsterPot bridge.
/// All network calls are performed with async/await URLSession APIs.
final class BridgeClient {

    let connection: BridgeConnection
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private var sseTask: Task<Void, Never>?
    private var lastEventCursor: String?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 86400
        return URLSession(configuration: config)
    }()

    init(connection: BridgeConnection) {
        self.connection = connection
    }

    func stop() {
        sseTask?.cancel()
        sseTask = nil
    }

    // MARK: - SSE event stream

    func startEventStream() {
        sseTask?.cancel()
        sseTask = Task { [weak self] in
            await self?.runSSELoop()
        }
    }

    private func runSSELoop() async {
        var backoff: UInt64 = 1_000_000_000  // 1 second
        while !Task.isCancelled {
            do {
                try await consumeSSEStream()
                backoff = 1_000_000_000
            } catch is CancellationError {
                break
            } catch {
                onConnectionChange?(false)
                try? await Task.sleep(nanoseconds: backoff)
                backoff = min(backoff * 2, 30_000_000_000)
            }
        }
    }

    private func consumeSSEStream() async throws {
        var urlComponents = URLComponents(string: baseURL + "/api/events")!
        if let cursor = lastEventCursor {
            urlComponents.queryItems = [URLQueryItem(name: "cursor", value: cursor)]
        }
        var request = URLRequest(url: urlComponents.url!)
        request.setValue(connection.deviceToken, forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw BridgeError.unexpectedStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        onConnectionChange?(true)

        var eventType: String?
        var eventData: String?
        var eventId: String?

        for try await line in bytes.lines {
            if Task.isCancelled { break }

            if line.hasPrefix("event: ") {
                eventType = String(line.dropFirst(7))
            } else if line.hasPrefix("data: ") {
                eventData = String(line.dropFirst(6))
            } else if line.hasPrefix("id: ") {
                eventId = String(line.dropFirst(4))
            } else if line.isEmpty {
                // Dispatch event
                if let type = eventType, let data = eventData {
                    if let id = eventId { lastEventCursor = id }
                    dispatchSSEEvent(type: type, data: data)
                }
                eventType = nil
                eventData = nil
                eventId = nil
            }
        }
    }

    private func dispatchSSEEvent(type: String, data: String) {
        guard type != "ping",
              let bytes = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { return }
        onEvent?(type, json)
    }

    // MARK: - Status

    func getStatus() async throws -> BridgeStatusResponse {
        try await get("/api/status")
    }

    // MARK: - Conversations

    func getConversations() async throws -> ConversationListResponse {
        try await get("/api/conversations")
    }

    func createConversation(title: String, purpose: String?, kind: String) async throws -> ConversationResponse {
        var body: [String: Any] = ["title": title, "kind": kind]
        if let purpose { body["purpose"] = purpose }
        return try await post("/api/conversations", body: body)
    }

    func patchConversation(id: String, title: String? = nil, pinned: Bool? = nil, archived: Bool? = nil) async throws -> ConversationResponse {
        var body: [String: Any] = [:]
        if let t = title { body["title"] = t }
        if let p = pinned { body["pinned"] = p }
        if let a = archived { body["archived"] = a }
        return try await patch("/api/conversations/\(id)", body: body)
    }

    // MARK: - Messages

    func getMessages(conversationId: String) async throws -> MessageListResponse {
        try await get("/api/conversations/\(conversationId)/messages")
    }

    func sendMessage(conversationId: String, text: String) async throws -> SendMessageResponse {
        try await post("/api/conversations/\(conversationId)/messages", body: ["text": text])
    }

    // MARK: - Approvals

    func respondToApproval(conversationId: String, approvalId: String, decision: String) async throws {
        let body: [String: Any] = [
            "type": "inbound.approval.respond",
            "conversationId": conversationId,
            "approvalId": approvalId,
            "decision": decision
        ]
        let _: EmptyResponse = try await post("/api/conversations/\(conversationId)/actions", body: body)
    }

    // MARK: - Setup

    func createToken() async throws -> TokenResponse {
        try await post("/api/setup/token", body: [:])
    }

    func getSnippet() async throws -> SnippetResponse {
        try await get("/api/setup/snippet")
    }

    func startPairing() async throws -> PairingStartResponse {
        try await post("/api/devices/pair/start", body: [:])
    }

    func finishPairing(pairingId: String, code: String) async throws -> PairingFinishResponse {
        try await post("/api/devices/pair/finish", body: ["pairingId": pairingId, "code": code])
    }

    // MARK: - Generic HTTP helpers

    private var baseURL: String { connection.bridgeUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        addAuthHeader(&request)
        let (data, response) = try await session.data(for: request)
        try checkStatus(response)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        try await send("POST", path: path, body: body)
    }

    private func patch<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        try await send("PATCH", path: path, body: body)
    }

    private func send<T: Decodable>(_ method: String, path: String, body: [String: Any]) async throws -> T {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        addAuthHeader(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try checkStatus(response)
        return try decoder.decode(T.self, from: data)
    }

    private func addAuthHeader(_ request: inout URLRequest) {
        request.setValue("Bearer \(connection.deviceToken)", forHTTPHeaderField: "Authorization")
    }

    private func checkStatus(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode >= 400 { throw BridgeError.unexpectedStatus(http.statusCode) }
    }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

// MARK: - Supplementary response types

struct PairingStartResponse: Codable {
    let pairingId: String
    let code: String
    let expiresAt: String
}

struct PairingFinishResponse: Codable {
    let deviceId: String
    let token: String
    let createdAt: String
}

private struct EmptyResponse: Codable {}

// MARK: - Errors

enum BridgeError: LocalizedError {
    case unexpectedStatus(Int)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let code): return "Bridge returned HTTP \(code)"
        case .decodingFailed(let detail): return "Response parsing failed: \(detail)"
        }
    }
}
