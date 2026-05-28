import Foundation

// MARK: - Core models mirroring @lobsterpot/protocol

struct LPConversation: Codable, Identifiable, Equatable {
    let id: String
    let openclawInstanceId: String?
    var title: String
    var purpose: String?
    let kind: ConversationKind
    let openclawSessionKey: String?
    let openclawAgentId: String?
    var pinned: Bool
    var archivedAt: String?
    let createdAt: String
    var updatedAt: String

    var displayTitle: String {
        kind == .main ? "Main Agent" : title
    }

    enum ConversationKind: String, Codable {
        case main, subagent, specialist, support, system
    }
}

struct LPMessage: Codable, Identifiable, Equatable {
    let id: String
    let conversationId: String
    let role: MessageRole
    var content: String
    var status: MessageStatus
    var attachments: [LPAttachment]
    let sourceEventId: String?
    let createdAt: String
    var updatedAt: String

    enum MessageRole: String, Codable {
        case user, assistant, system, tool
    }

    enum MessageStatus: String, Codable {
        case queued, sending, sent, streaming, final, failed, cancelled
    }

    var timestamp: Date {
        ISO8601DateFormatter().date(from: createdAt) ?? Date()
    }
}

struct LPAttachment: Codable, Identifiable, Equatable {
    let id: String
    let filename: String
    let contentType: String
    let byteSize: Int
    let url: String?
    let createdAt: String
}

struct PendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let filename: String
    let contentType: String
    let data: Data
}

struct LPApprovalRequest: Identifiable {
    let id: String
    let conversationId: String
    let approvalId: String
    let title: String
    let body: String?
    let expiresAt: String?
}

// MARK: - Bridge connection settings

struct BridgeConnection: Equatable {
    /// e.g. "https://my-bridge.fly.dev" — stored in UserDefaults (not secret)
    var bridgeUrl: String
    /// "device_<token>" returned by /api/devices/pair/finish — stored in Keychain
    var deviceToken: String

    static let urlStorageKey = "bridge_url_v1"
    static let keychainService = "com.lobsterpot.app"
    static let keychainAccount = "deviceToken"
}

// MARK: - Bridge API response envelopes

struct ConversationListResponse: Codable {
    let conversations: [LPConversation]
}

struct SearchResponse: Codable {
    let conversations: [LPConversation]
    let messages: [LPMessage]
}

struct ConversationResponse: Codable {
    let conversation: LPConversation
}

struct MessageListResponse: Codable {
    let messages: [LPMessage]
}

struct AttachmentResponse: Codable {
    let attachment: LPAttachment
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

struct OpenClawInstance: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let connected: Bool
    let capabilities: [String]
    let lastSeenAt: String?
    let createdAt: String
    let updatedAt: String
}

struct OpenClawListResponse: Codable {
    let openclaws: [OpenClawInstance]
}

struct CreateOpenClawResponse: Codable {
    let openclaw: OpenClawInstance
    let token: String
}

struct OpenClawResponse: Codable {
    let openclaw: OpenClawInstance
}

struct PushRegistrationResponse: Codable {
    let ok: Bool
    let relayConfigured: Bool
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

struct EmptyResponse: Codable {}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}
