import Foundation

// MARK: - Frame discriminator

/// Used to identify the top-level frame type before full decoding.
struct GFFrameType: Decodable {
    let type: String
}

// MARK: - Outbound request

struct GFRequest: Encodable {
    let type = "req"
    let id: String
    let method: String
    let params: GFAnyEncodable?

    init(id: String, method: String, params: [String: Any]? = nil) {
        self.id = id
        self.method = method
        self.params = params.map(GFAnyEncodable.init)
    }
}

// MARK: - Inbound response

struct GFResponse: Decodable {
    let type: String   // "res"
    let id: String
    let ok: Bool
    let payload: GFAnyDecodable?
    let error: GFError?
}

struct GFError: Decodable {
    let code: String
    let message: String
    let details: GFErrorDetails?
    let retryable: Bool?
    let retryAfterMs: Int?
}

struct GFErrorDetails: Decodable {
    let canRetryWithDeviceToken: Bool?
    let recommendedNextStep: String?
    let reason: String?
}

// MARK: - Inbound event

struct GFEvent: Decodable {
    let type: String   // "event"
    let event: String
    let payload: GFAnyDecodable?
    let seq: Int?
}

// MARK: - connect.challenge

struct ConnectChallengePayload: Decodable {
    let nonce: String
    let ts: Int
}

// MARK: - connect request params

struct ConnectParams: Encodable {
    let minProtocol: Int = 3
    let maxProtocol: Int = 4
    let client: ConnectClientInfo
    let role: String
    let scopes: [String]
    let caps: [String]?
    let commands: [String]?
    let device: DeviceConnectParams?
    let auth: ConnectAuth?
    let locale: String?
    let userAgent: String?
}

struct ConnectClientInfo: Encodable {
    let id: String
    let version: String
    let platform: String
    let deviceFamily: String
    let mode: String
    let displayName: String?
}

struct DeviceConnectParams: Encodable {
    let id: String
    let publicKey: String
    let signature: String
    let signedAt: Int
    let nonce: String
}

struct ConnectAuth: Encodable {
    let token: String?
    let deviceToken: String?
}

// MARK: - hello-ok payload

struct HelloOkPayload: Decodable {
    let type: String       // "hello-ok"
    let protocol_: Int
    let server: HelloServer
    let auth: HelloAuth
    let policy: HelloPolicy
    let features: HelloFeatures

    enum CodingKeys: String, CodingKey {
        case type
        case protocol_ = "protocol"
        case server, auth, policy, features
    }
}

struct HelloServer: Decodable {
    let version: String
    let connId: String
}

struct HelloAuth: Decodable {
    let deviceToken: String?
    let role: String
    let scopes: [String]
}

struct HelloPolicy: Decodable {
    let maxPayload: Int
    let maxBufferedBytes: Int
    let tickIntervalMs: Int
}

struct HelloFeatures: Decodable {
    let methods: [String]
    let events: [String]
}

// MARK: - sessions.list

struct SessionsListParams: Encodable {
    let limit: Int?
    let agentId: String?
    let includeDerivedTitles: Bool?
    let includeLastMessage: Bool?
    let configuredAgentsOnly: Bool?
}

struct SessionsListResult: Decodable {
    let sessions: [GWSessionRow]
}

/// A session row from sessions.list. Mirrors the gateway's session index entry.
struct GWSessionRow: Decodable, Identifiable {
    /// The stable session key, e.g. "agent:main:main" or "agent:main:subagent:<uuid>"
    let key: String
    let sessionId: String?
    let agentId: String?
    let label: String?
    let derivedTitle: String?
    let lastMessage: GWLastMessage?
    let createdAt: Int?
    let updatedAt: Int?
    let spawnedBy: String?

    var id: String { key }

    /// Human-readable display name for the session.
    var displayName: String {
        if let label, !label.isEmpty { return label }
        if let title = derivedTitle, !title.isEmpty { return title }
        if key.contains(":subagent:") {
            let parts = key.split(separator: ":")
            if let last = parts.last {
                return "Subagent \(String(last.prefix(8)))"
            }
        }
        if let agentId, key.hasSuffix(":main") { return agentId.capitalized }
        return key.split(separator: ":").last.map(String.init) ?? key
    }

    var isMain: Bool { key.hasSuffix(":main") }
    var isSubagent: Bool { key.contains(":subagent:") }
}

struct GWLastMessage: Decodable {
    let role: String?
    let text: String?
    let ts: Int?
}

// MARK: - sessions.send

struct SessionsSendParams: Encodable {
    let key: String
    let message: String
    let idempotencyKey: String?
}

// MARK: - sessions.messages.subscribe / unsubscribe

struct SessionsMessagesSubscribeParams: Encodable {
    let key: String
}

// MARK: - sessions.subscribe (sessions changed)

struct SessionsSubscribeParams: Encodable {
    let agentId: String?
}

// MARK: - chat.history

struct ChatHistoryParams: Encodable {
    let sessionKey: String
    let limit: Int?
}

struct ChatHistoryResult: Decodable {
    let messages: [GWChatMessage]
}

struct GWChatMessage: Decodable, Identifiable {
    let id: String
    let role: String     // "user" | "assistant" | "system" | "tool"
    let text: String?
    let ts: Int?
    let runId: String?
}

// MARK: - session.message event payload

struct SessionMessageEventPayload: Decodable {
    let sessionKey: String
    let role: String?
    let text: String?
    let deltaText: String?
    let replace: Bool?
    let runId: String?
    let ts: Int?
    let status: String?   // "streaming" | "final" | "error"
}

// MARK: - sessions.changed event payload

struct SessionsChangedPayload: Decodable {
    let keys: [String]?
    let agentId: String?
}

// MARK: - sessions.create

struct SessionsCreateParams: Encodable {
    let agentId: String?
    let label: String?
    let message: String?
}

// MARK: - Helpers for arbitrary JSON encode/decode

/// Wraps a `[String: Any]` for Encoding.
struct GFAnyEncodable: Encodable {
    let value: [String: Any]

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(AnyCodableValue(value))
    }
}

/// Wraps an arbitrary JSON value for Decoding.
struct GFAnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodableValue].self) {
            value = dict.mapValues { $0.value }
        } else if let arr = try? container.decode([AnyCodableValue].self) {
            value = arr.map { $0.value }
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let dbl = try? container.decode(Double.self) {
            value = dbl
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = NSNull()
        }
    }

    func decoded<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Used internally for arbitrary JSON roundtrip.
private struct AnyCodableValue: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode([String: AnyCodableValue].self) {
            value = v.mapValues { $0.value }
        } else if let v = try? container.decode([AnyCodableValue].self) {
            value = v.map { $0.value }
        } else if container.decodeNil() { value = NSNull() }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown type") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let s as String: try container.encode(s)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let b as Bool: try container.encode(b)
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodableValue($0) })
        case let arr as [Any]:
            try container.encode(arr.map { AnyCodableValue($0) })
        default: try container.encodeNil()
        }
    }
}
