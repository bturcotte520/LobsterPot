import Foundation

// MARK: - Session (inbox row)

/// One row in the iMessage-style inbox.
/// Mirrors `GWSessionRow` but adds UI-computed properties and local state.
struct LPSession: Identifiable, Equatable {
    let id: String                  // session key, e.g. "agent:main:main"
    let workspaceId: UUID
    var displayName: String
    var lastMessagePreview: String?
    var lastMessageTs: Date?
    var isMain: Bool
    var isSubagent: Bool
    var hasUnread: Bool

    init(row: GWSessionRow, workspaceId: UUID) {
        self.id = row.key
        self.workspaceId = workspaceId
        self.displayName = row.displayName
        self.lastMessagePreview = row.lastMessage?.text.flatMap {
            $0.isEmpty ? nil : String($0.prefix(120))
        }
        if let ts = row.lastMessage?.ts {
            self.lastMessageTs = Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        }
        self.isMain = row.isMain
        self.isSubagent = row.isSubagent
        self.hasUnread = false
    }
}

// MARK: - Chat message

/// A single message in a chat thread.
struct LPMessage: Identifiable, Equatable {
    enum Role: String, Equatable { case user, assistant, system, tool }
    enum Status: Equatable { case final_, streaming, error }

    let id: String
    let sessionKey: String
    var role: Role
    var text: String
    var status: Status
    var timestamp: Date

    init(id: String = UUID().uuidString, sessionKey: String, role: Role,
         text: String, status: Status = .final_, timestamp: Date = Date()) {
        self.id = id
        self.sessionKey = sessionKey
        self.role = role
        self.text = text
        self.status = status
        self.timestamp = timestamp
    }

    init(chatRow: GWChatMessage, sessionKey: String) {
        self.id = chatRow.id
        self.sessionKey = sessionKey
        self.role = Role(rawValue: chatRow.role) ?? .assistant
        self.text = chatRow.text ?? ""
        self.status = .final_
        self.timestamp = chatRow.ts.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } ?? Date()
    }
}

// MARK: - Approval request

struct LPApprovalRequest: Identifiable {
    let id: String
    let sessionKey: String
    let title: String
    let body: String?
    let expiresAt: Date?
}
