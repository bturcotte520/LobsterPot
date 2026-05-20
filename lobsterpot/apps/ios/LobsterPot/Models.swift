import Foundation

// MARK: - Core models mirroring @lobsterpot/protocol

struct LPConversation: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var purpose: String?
    let kind: ConversationKind
    var pinned: Bool
    var archivedAt: String?
    let createdAt: String
    var updatedAt: String

    enum ConversationKind: String, Codable {
        case main, specialist, support, system
    }
}

struct LPMessage: Codable, Identifiable, Equatable {
    let id: String
    let conversationId: String
    let role: MessageRole
    var content: String
    var status: MessageStatus
    let sourceEventId: String?
    let createdAt: String
    var updatedAt: String

    enum MessageRole: String, Codable {
        case user, assistant, system, tool
    }

    enum MessageStatus: String, Codable {
        case queued, sending, sent, streaming, final, failed, cancelled
    }
}

struct LPApprovalRequest: Identifiable {
    let id: String
    let conversationId: String
    let approvalId: String
    let title: String
    let body: String?
    let expiresAt: String?
}

// MARK: - Bridge API response envelopes

struct ConversationListResponse: Codable {
    let conversations: [LPConversation]
}

struct ConversationResponse: Codable {
    let conversation: LPConversation
}

struct MessageListResponse: Codable {
    let messages: [LPMessage]
}

struct SendMessageResponse: Codable {
    let message: LPMessage
    let eventId: String?
}

struct BridgeStatusResponse: Codable {
    let ok: Bool
    let service: String
    let plugin: PluginStatus
    let publicBaseUrl: String?
    let now: String

    struct PluginStatus: Codable {
        let connected: Bool
        let status: String
        let instanceId: String?
        let lastSeenAt: String?
        let capabilities: [String]
    }
}

struct TokenResponse: Codable {
    let id: String
    let token: String
    let createdAt: String
}

struct SnippetResponse: Codable {
    let json5: String
    let bridgeUrl: String
}

// MARK: - SSE event envelope

struct BridgeSSEEvent: Codable {
    let id: String
    let cursor: String
    let type: String
    let conversationId: String?
    let createdAt: String
}

// MARK: - Persisted connection settings

struct BridgeConnection: Equatable {
    var bridgeUrl: String   // e.g. "https://my-bridge.fly.dev"  — stored in UserDefaults
    var deviceToken: String // "device_<id>" returned by /api/devices/pair/finish — stored in Keychain

    // UserDefaults key for the non-secret bridgeUrl
    static let urlStorageKey = "bridge_url_v1"
    // Keychain service + account for the sensitive deviceToken
    static let keychainService = "com.lobsterpot.app"
    static let keychainAccount = "deviceToken"
}
