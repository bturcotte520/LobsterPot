import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {

    // MARK: - Workspace management

    @Published var workspaceStore = WorkspaceStore()
    @Published var activeWorkspaceId: UUID?

    // MARK: - Sessions (inbox rows), keyed by workspaceId

    @Published var sessions: [UUID: [LPSession]] = [:]

    // MARK: - Messages, keyed by sessionKey

    @Published var messages: [String: [LPMessage]] = [:]

    // MARK: - Connection states, keyed by workspaceId

    @Published var connectionStates: [UUID: GatewayConnectionState] = [:]

    // MARK: - Loading states

    @Published var isLoadingSessions = false
    @Published var loadingMessageSession: String?
    @Published var sendingInSession: String?

    // MARK: - Error banner

    @Published var lastError: String?

    // MARK: - Private

    private let identity = DeviceIdentity.loadOrCreate()
    private var clients: [UUID: GatewayClient] = [:]

    // MARK: - Active workspace helpers

    var activeWorkspace: Workspace? {
        guard let id = activeWorkspaceId else { return nil }
        return workspaceStore.workspaces.first { $0.id == id }
    }

    var activeSessions: [LPSession] {
        guard let id = activeWorkspaceId else { return [] }
        return sessions[id] ?? []
    }

    var activeConnectionState: GatewayConnectionState {
        guard let id = activeWorkspaceId else { return .disconnected }
        return connectionStates[id] ?? .disconnected
    }

    // MARK: - Workspace lifecycle

    func addWorkspace(_ workspace: Workspace) {
        workspaceStore.add(workspace)
        connectWorkspace(workspace)
        if activeWorkspaceId == nil {
            activeWorkspaceId = workspace.id
        }
    }

    func removeWorkspace(_ workspace: Workspace) {
        clients[workspace.id]?.stop()
        clients.removeValue(forKey: workspace.id)
        sessions.removeValue(forKey: workspace.id)
        connectionStates.removeValue(forKey: workspace.id)
        workspaceStore.remove(workspace)
        if activeWorkspaceId == workspace.id {
            activeWorkspaceId = workspaceStore.workspaces.first?.id
        }
    }

    func switchWorkspace(to id: UUID) {
        activeWorkspaceId = id
    }

    /// Call on app launch to reconnect all previously paired workspaces.
    func connectAllWorkspaces() {
        for ws in workspaceStore.workspaces {
            if clients[ws.id] == nil {
                connectWorkspace(ws)
            }
        }
        if activeWorkspaceId == nil {
            activeWorkspaceId = workspaceStore.workspaces.first?.id
        }
    }

    private func connectWorkspace(_ workspace: Workspace) {
        let hydrated = workspaceStore.hydrated(workspace)
        let client = GatewayClient(workspace: hydrated, identity: identity)

        client.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.connectionStates[workspace.id] = state
            }
        }

        client.onSessionsChanged = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refreshSessions(for: workspace.id)
            }
        }

        client.onSessionMessage = { [weak self] payload in
            Task { @MainActor [weak self] in
                self?.handleSessionMessage(payload)
            }
        }

        clients[workspace.id] = client
        client.start()
    }

    // MARK: - Session operations

    func refreshSessions(for workspaceId: UUID) async {
        guard let client = clients[workspaceId] else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        do {
            let rows = try await client.listSessions()
            let lpSessions = rows.map { LPSession(row: $0, workspaceId: workspaceId) }
            sessions[workspaceId] = lpSessions
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createSession(label: String? = nil) async -> LPSession? {
        guard let id = activeWorkspaceId, let client = clients[id] else { return nil }
        do {
            guard let row = try await client.createSession(label: label) else { return nil }
            let session = LPSession(row: row, workspaceId: id)
            if sessions[id] != nil {
                sessions[id]!.insert(session, at: 0)
            } else {
                sessions[id] = [session]
            }
            return session
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: - Message operations

    func loadMessages(sessionKey: String) async {
        guard let id = activeWorkspaceId, let client = clients[id] else { return }
        loadingMessageSession = sessionKey
        defer { loadingMessageSession = nil }
        do {
            let rows = try await client.loadHistory(sessionKey: sessionKey)
            messages[sessionKey] = rows.map { LPMessage(chatRow: $0, sessionKey: sessionKey) }
            try await client.subscribeMessages(sessionKey: sessionKey)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func unloadMessages(sessionKey: String) async {
        guard let id = activeWorkspaceId, let client = clients[id] else { return }
        try? await client.unsubscribeMessages(sessionKey: sessionKey)
    }

    func sendMessage(sessionKey: String, text: String) async {
        guard let id = activeWorkspaceId, let client = clients[id] else { return }

        // Optimistic: show user message immediately
        let userMsg = LPMessage(
            sessionKey: sessionKey, role: .user, text: text,
            status: .final_, timestamp: Date()
        )
        upsertMessage(userMsg)

        sendingInSession = sessionKey
        defer { sendingInSession = nil }

        do {
            try await client.sendToSession(sessionKey, message: text)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Incoming event handling

    private func handleSessionMessage(_ payload: SessionMessageEventPayload) {
        let sessionKey = payload.sessionKey
        let role = LPMessage.Role(rawValue: payload.role ?? "assistant") ?? .assistant

        if let delta = payload.deltaText, !delta.isEmpty {
            // Streaming: append delta to last assistant message in this session
            if let idx = messages[sessionKey]?.lastIndex(where: { $0.role == .assistant && $0.status == .streaming }) {
                messages[sessionKey]![idx].text += delta
            } else {
                // Start new streaming message
                let id = payload.runId ?? UUID().uuidString
                let msg = LPMessage(
                    id: id, sessionKey: sessionKey, role: role,
                    text: delta, status: .streaming
                )
                upsertMessage(msg)
            }
        } else if payload.replace == true, let text = payload.text {
            // Replace: overwrite last assistant message
            if let idx = messages[sessionKey]?.lastIndex(where: { $0.role == .assistant }) {
                messages[sessionKey]![idx].text = text
                messages[sessionKey]![idx].status = payload.status == "final" ? .final_ : .streaming
            }
        } else if let text = payload.text, !text.isEmpty {
            // Full message
            let id = payload.runId ?? UUID().uuidString
            let status: LPMessage.Status = payload.status == "streaming" ? .streaming : .final_
            let msg = LPMessage(id: id, sessionKey: sessionKey, role: role, text: text, status: status)
            upsertMessage(msg)
        }

        // Update session preview
        if let wsId = activeWorkspaceId, var list = sessions[wsId],
           let si = list.firstIndex(where: { $0.id == sessionKey })
        {
            list[si].lastMessagePreview = (payload.text ?? payload.deltaText).flatMap {
                $0.isEmpty ? nil : String($0.prefix(120))
            }
            list[si].lastMessageTs = Date()
            sessions[wsId] = list
        }
    }

    // MARK: - Helpers

    private func upsertMessage(_ msg: LPMessage) {
        var list = messages[msg.sessionKey] ?? []
        if let idx = list.firstIndex(where: { $0.id == msg.id }) {
            list[idx] = msg
        } else {
            list.append(msg)
        }
        messages[msg.sessionKey] = list
    }
}
