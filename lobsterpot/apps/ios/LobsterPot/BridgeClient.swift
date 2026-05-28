import Foundation
import CryptoKit

/// HTTP + SSE client for the LobsterPot bridge.
final class BridgeClient: @unchecked Sendable {

    let connection: BridgeConnection
    var onEvent: ((String, [String: Any]) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

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
        sseStream?.stop()
        sseStream = nil
    }

    // MARK: - SSE event stream

    private var sseStream: SSEStream?

    func startEventStream() {
        sseStream?.stop()
        guard let url = URL(string: baseURL + "/api/events") else { return }
        let stream = SSEStream(
            url: url,
            bearerToken: connection.deviceToken,
            lastEventId: lastEventCursor,
            onEvent: { [weak self] id, event, data in
                if let id = id { self?.lastEventCursor = id }
                self?.dispatchSSEEvent(type: event, data: data)
            },
            onConnectionChange: { [weak self] connected in
                self?.onConnectionChange?(connected)
                if !connected {
                    // Reconnect after a short delay if not explicitly stopped
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        self?.startEventStream()
                    }
                }
            },
            onError: { _ in /* swallowed; reconnect handled above */ }
        )
        sseStream = stream
        stream.start()
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

    func registerPushToken(_ token: String, environment: String) async throws -> PushRegistrationResponse {
        try await post("/api/push/register", body: [
            "apnsToken": token,
            "environment": environment
        ])
    }

    func sendTestPush() async throws -> EmptyResponse {
        try await post("/api/push/test", body: [:])
    }

    // MARK: - Conversations

    func getConversations(archived: Bool = false, openclawInstanceId: String? = nil) async throws -> ConversationListResponse {
        var parts: [String] = []
        if archived { parts.append("archived=true") }
        if let openclawInstanceId { parts.append("openclawInstanceId=\(openclawInstanceId)") }
        let query = parts.isEmpty ? "" : "?\(parts.joined(separator: "&"))"
        return try await get("/api/conversations\(query)")
    }

    func getOpenClaws() async throws -> OpenClawListResponse {
        try await get("/api/openclaws")
    }

    func createOpenClaw(name: String) async throws -> CreateOpenClawResponse {
        try await post("/api/openclaws", body: ["name": name])
    }

    func updateOpenClaw(id: String, name: String? = nil, revoked: Bool? = nil) async throws -> OpenClawInstance {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let revoked { body["revoked"] = revoked }
        let response: OpenClawResponse = try await patch("/api/openclaws/\(id)", body: body)
        return response.openclaw
    }

    func search(query: String, includeArchived: Bool = false, openclawInstanceId: String? = nil) async throws -> SearchResponse {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        let archived = includeArchived ? "&includeArchived=true" : ""
        let instance = openclawInstanceId.map { "&openclawInstanceId=\($0)" } ?? ""
        return try await get("/api/search?q=\(encoded)\(archived)\(instance)")
    }

    func createConversation(title: String, purpose: String?, kind: String, openclawInstanceId: String? = nil) async throws -> ConversationResponse {
        var body: [String: Any] = ["title": title, "kind": kind]
        if let purpose { body["purpose"] = purpose }
        if let openclawInstanceId { body["openclawInstanceId"] = openclawInstanceId }
        return try await post("/api/conversations", body: body)
    }

    func patchConversation(id: String, title: String? = nil, pinned: Bool? = nil, archived: Bool? = nil) async throws -> ConversationResponse {
        var body: [String: Any] = [:]
        if let t = title { body["title"] = t }
        if let p = pinned { body["pinned"] = p }
        if let a = archived { body["archived"] = a }
        return try await patch("/api/conversations/\(id)", body: body)
    }

    func deleteConversation(id: String) async throws {
        let _: EmptyResponse = try await delete("/api/conversations/\(id)")
    }

    // MARK: - Messages

    func getMessages(conversationId: String) async throws -> MessageListResponse {
        try await get("/api/conversations/\(conversationId)/messages")
    }

    func uploadAttachment(data: Data, filename: String, contentType: String) async throws -> AttachmentResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: \(contentType)\r\n\r\n")
        body.append(data)
        body.appendString("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: baseURL + "/api/attachments")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        addAuthHeader(&request)
        request.httpBody = body
        let (responseData, response) = try await session.data(for: request)
        try checkStatus(response)
        return try decoder.decode(AttachmentResponse.self, from: responseData)
    }

    func sendMessage(conversationId: String, text: String, attachmentIds: [String] = []) async throws -> SendMessageResponse {
        try await post("/api/conversations/\(conversationId)/messages", body: [
            "text": text,
            "attachmentIds": attachmentIds
        ])
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

    // MARK: - Pairing (PKCE)

    func startPairing() async throws -> (response: PairingStartResponse, codeVerifier: String) {
        let codeVerifier = generateCodeVerifier()
        let codeChallenge = sha256Hex(codeVerifier)
        let response: PairingStartResponse = try await post(
            "/api/devices/pair/start",
            body: ["codeChallenge": codeChallenge]
        )
        return (response, codeVerifier)
    }

    func finishPairing(pairingId: String, code: String, codeVerifier: String) async throws -> PairingFinishResponse {
        try await post("/api/devices/pair/finish", body: [
            "pairingId": pairingId,
            "code": code,
            "codeVerifier": codeVerifier
        ])
    }

    // MARK: - PKCE helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func sha256Hex(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Generic HTTP helpers

    private var baseURL: String {
        connection.bridgeUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

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

    private func delete<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: URL(string: baseURL + path)!)
        request.httpMethod = "DELETE"
        addAuthHeader(&request)
        let (data, response) = try await session.data(for: request)
        try checkStatus(response)
        return try decoder.decode(T.self, from: data)
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
        if http.statusCode >= 400 {
            throw BridgeError.unexpectedStatus(http.statusCode)
        }
    }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

private extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}

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
