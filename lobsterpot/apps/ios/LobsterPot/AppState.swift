import Foundation
import Combine
import UserNotifications

@MainActor
final class AppState: ObservableObject {

    // MARK: - Connection
    @Published var connection: BridgeConnection?
    @Published var isConnected = false
    @Published var pluginConnected = false

    // MARK: - Conversations
    @Published var conversations: [LPConversation] = []
    @Published var selectedConversationId: String?

    // MARK: - Messages keyed by conversation ID
    @Published var messages: [String: [LPMessage]] = [:]

    // MARK: - Pending approvals
    @Published var pendingApprovals: [LPApprovalRequest] = []

    // MARK: - Error banner
    @Published var lastError: String?

    // MARK: - Loading states
    @Published var isLoadingConversations = false
    @Published var sendingInConversation: String?

    private var bridgeClient: BridgeClient?
    private var refreshTask: Task<Void, Never>?

    // MARK: - Setup

    func connect(to connection: BridgeConnection) {
        self.connection = connection
        persist(connection)
        startBridgeClient(connection)
    }

    func disconnect() {
        bridgeClient?.stop()
        bridgeClient = nil
        connection = nil
        isConnected = false
        pluginConnected = false
        conversations = []
        messages = [:]
        pendingApprovals = []
        UserDefaults.standard.removeObject(forKey: BridgeConnection.storageKey)
    }

    func loadPersistedConnection() {
        guard let data = UserDefaults.standard.data(forKey: BridgeConnection.storageKey),
              let conn = try? JSONDecoder().decode(BridgeConnection.self, from: data) else { return }
        connection = conn
        startBridgeClient(conn)
    }

    // MARK: - Conversation operations

    func refreshConversations() async {
        guard let client = bridgeClient else { return }
        isLoadingConversations = true
        defer { isLoadingConversations = false }
        do {
            let resp = try await client.getConversations()
            conversations = resp.conversations.sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                return $0.updatedAt > $1.updatedAt
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createConversation(title: String, purpose: String? = nil, kind: LPConversation.ConversationKind = .specialist) async -> LPConversation? {
        guard let client = bridgeClient else { return nil }
        do {
            let resp = try await client.createConversation(title: title, purpose: purpose, kind: kind.rawValue)
            conversations.insert(resp.conversation, at: 0)
            return resp.conversation
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func pinConversation(_ id: String, pinned: Bool) async {
        guard let client = bridgeClient else { return }
        do {
            let resp = try await client.patchConversation(id: id, pinned: pinned)
            applyConversationUpdate(resp.conversation)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func archiveConversation(_ id: String) async {
        guard let client = bridgeClient else { return }
        do {
            let resp = try await client.patchConversation(id: id, archived: true)
            conversations.removeAll { $0.id == id }
            _ = resp
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Message operations

    func loadMessages(conversationId: String) async {
        guard let client = bridgeClient else { return }
        do {
            let resp = try await client.getMessages(conversationId: conversationId)
            messages[conversationId] = resp.messages
        } catch {
            lastError = error.localizedDescription
        }
    }

    func sendMessage(conversationId: String, text: String) async {
        guard let client = bridgeClient else { return }
        sendingInConversation = conversationId
        defer { sendingInConversation = nil }
        do {
            let resp = try await client.sendMessage(conversationId: conversationId, text: text)
            upsertMessage(resp.message)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Approval operations

    func respondToApproval(conversationId: String, approvalId: String, decision: String) async {
        guard let client = bridgeClient else { return }
        do {
            try await client.respondToApproval(conversationId: conversationId, approvalId: approvalId, decision: decision)
            pendingApprovals.removeAll { $0.approvalId == approvalId }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - SSE event handling

    func handleSSEEvent(type: String, payload: [String: Any]) {
        switch type {
        case "outbound.message":
            guard
                let convId = payload["conversationId"] as? String,
                let msgData = try? JSONSerialization.data(withJSONObject: payload),
                let event = try? JSONDecoder().decode(OutboundMessagePayload.self, from: msgData)
            else { return }

            let msg = LPMessage(
                id: event.messageId,
                conversationId: convId,
                role: .assistant,
                content: event.text,
                status: event.status == "final" ? .final : .streaming,
                sourceEventId: event.id,
                createdAt: event.createdAt ?? "",
                updatedAt: event.createdAt ?? ""
            )
            upsertMessage(msg)
            touchConversation(convId)

        case "outbound.progress":
            break // progress UI handled per-view if needed

        case "outbound.approval.requested":
            guard
                let convId = payload["conversationId"] as? String,
                let approvalId = payload["approvalId"] as? String,
                let title = payload["title"] as? String,
                let eventId = payload["id"] as? String
            else { return }
            let req = LPApprovalRequest(
                id: eventId,
                conversationId: convId,
                approvalId: approvalId,
                title: title,
                body: payload["body"] as? String,
                expiresAt: payload["expiresAt"] as? String
            )
            pendingApprovals.append(req)

        case "conversation.created", "conversation.updated":
            Task { await refreshConversations() }

        case "plugin.connected":
            pluginConnected = true

        case "plugin.disconnected":
            pluginConnected = false

        default:
            break
        }
    }

    // MARK: - Private helpers

    private func startBridgeClient(_ conn: BridgeConnection) {
        bridgeClient?.stop()
        let client = BridgeClient(connection: conn)
        bridgeClient = client
        client.onEvent = { [weak self] type, payload in
            Task { @MainActor in
                self?.handleSSEEvent(type: type, payload: payload)
            }
        }
        client.onConnectionChange = { [weak self] connected in
            Task { @MainActor in
                self?.isConnected = connected
            }
        }
        Task {
            await refreshConversations()
            await checkStatus()
        }
        client.startEventStream()
    }

    private func checkStatus() async {
        guard let client = bridgeClient else { return }
        do {
            let status = try await client.getStatus()
            pluginConnected = status.plugin.connected
        } catch {
            // non-fatal
        }
    }

    private func persist(_ conn: BridgeConnection) {
        if let data = try? JSONEncoder().encode(conn) {
            UserDefaults.standard.set(data, forKey: BridgeConnection.storageKey)
        }
    }

    private func upsertMessage(_ msg: LPMessage) {
        var list = messages[msg.conversationId] ?? []
        if let idx = list.firstIndex(where: { $0.id == msg.id }) {
            list[idx] = msg
        } else {
            list.append(msg)
        }
        messages[msg.conversationId] = list
    }

    private func applyConversationUpdate(_ conv: LPConversation) {
        if let idx = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[idx] = conv
        }
    }

    private func touchConversation(_ id: String) {
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            var conv = conversations[idx]
            conv = LPConversation(
                id: conv.id, title: conv.title, purpose: conv.purpose,
                kind: conv.kind, pinned: conv.pinned, archivedAt: conv.archivedAt,
                createdAt: conv.createdAt, updatedAt: ISO8601DateFormatter().string(from: Date())
            )
            conversations[idx] = conv
            conversations.sort { $0.pinned != $1.pinned ? $0.pinned : $0.updatedAt > $1.updatedAt }
        }
    }
}

// Small decodable for SSE outbound.message payload
private struct OutboundMessagePayload: Decodable {
    let id: String
    let messageId: String
    let conversationId: String
    let text: String
    let status: String
    let createdAt: String?
}
