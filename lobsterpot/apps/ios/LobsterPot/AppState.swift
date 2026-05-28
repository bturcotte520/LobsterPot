import Foundation
import Combine
import UIKit
import UserNotifications

@MainActor
final class AppState: ObservableObject {

    // MARK: - Workspace store
    let workspaceStore = WorkspaceStore()

    // MARK: - Per-workspace state
    /// Active BridgeClient for the active workspace. nil during setup.
    @Published private(set) var bridgeClient: BridgeClient?

    /// Connection state (SSE) per workspace.
    @Published var isConnected = false
    @Published var pluginConnected = false

    // MARK: - Conversations / messages (active workspace only)
    @Published var conversations: [LPConversation] = []
    @Published var openclaws: [OpenClawInstance] = []
    @Published var activeOpenClawId: String?
    @Published var archivedConversations: [LPConversation] = []
    @Published var selectedConversationId: String?
    @Published var messages: [String: [LPMessage]] = [:]
    @Published var mutedConversationIds: Set<String> = []
    @Published var searchResults: SearchResponse?

    // MARK: - Loading state
    @Published var isLoadingConversations = false
    @Published var sendingInConversation: String?
    @Published var loadingMessageConversation: String?
    @Published var newSubagentConversation: LPConversation?
    @Published var recentlyArchivedConversation: LPConversation?
    @Published private var typingConversationIds: Set<String> = []
    private var conversationCreatedNotificationCutoff = Date()
    private var pendingApnsToken: String?
    private var surfacedCreatedConversationIds: Set<String> = []

    // MARK: - Pending approvals
    @Published var pendingApprovals: [LPApprovalRequest] = []

    // MARK: - Error banner
    @Published var lastError: String?
    @Published var appearanceMode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: Self.appearanceModeKey)
        }
    }

    // MARK: - Setup state convenience
    var isSetupComplete: Bool { !workspaceStore.workspaces.isEmpty }
    var activeWorkspace: Workspace? { workspaceStore.activeWorkspace }
    var activeWorkspaceId: UUID? { workspaceStore.activeWorkspaceId }
    var activeOpenClaw: OpenClawInstance? {
        guard let activeOpenClawId else { return nil }
        return openclaws.first { $0.id == activeOpenClawId }
    }

    private static let appearanceModeKey = "appearance_mode_v1"

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.appearanceModeKey)
        appearanceMode = AppearanceMode(rawValue: raw ?? "system") ?? .system
    }

    // MARK: - Lifecycle

    /// Connect using an active workspace (called on launch + when switching workspaces).
    func connectToActiveWorkspace() {
        guard let ws = workspaceStore.activeWorkspace,
              let token = workspaceStore.deviceToken(for: ws.id) else {
            // No active workspace — disconnect any existing client
            tearDownClient()
            return
        }
        startClient(bridgeUrl: ws.bridgeUrl, deviceToken: token)
    }

    /// Add a new workspace and immediately switch to it.
    func addWorkspace(name: String, bridgeUrl: String, deviceToken: String) {
        let colorIdx = workspaceStore.workspaces.count
        let workspace = Workspace(name: name, bridgeUrl: bridgeUrl, colorIndex: colorIdx)
        workspaceStore.add(workspace, deviceToken: deviceToken)
        workspaceStore.setActive(workspace.id)
        connectToActiveWorkspace()
    }

    /// Switch to a different existing workspace.
    func switchWorkspace(to id: UUID) {
        guard id != workspaceStore.activeWorkspaceId else { return }
        workspaceStore.setActive(id)
        connectToActiveWorkspace()
    }

    /// Remove a workspace. If it was active, switches to the next one (or no workspace).
    func removeWorkspace(_ id: UUID) {
        let wasActive = workspaceStore.activeWorkspaceId == id
        workspaceStore.remove(id)
        if wasActive {
            connectToActiveWorkspace()
        }
    }

    // MARK: - Private: client lifecycle

    private func startClient(bridgeUrl: String, deviceToken: String) {
        tearDownClient()
        conversationCreatedNotificationCutoff = Date()
        loadSurfacedCreatedConversationIds()
        let conn = BridgeConnection(bridgeUrl: bridgeUrl, deviceToken: deviceToken)
        let client = BridgeClient(connection: conn)
        bridgeClient = client

        client.onEvent = { [weak self] type, payload in
            Task { @MainActor in self?.handleSSEEvent(type: type, payload: payload) }
        }
        client.onConnectionChange = { [weak self] connected in
            Task { @MainActor in self?.isConnected = connected }
        }

        Task {
            await refreshOpenClaws()
            await refreshConversations()
            await checkStatus()
            await registerPendingPushTokenIfNeeded()
        }
        client.startEventStream()
    }

    private func tearDownClient() {
        bridgeClient?.stop()
        bridgeClient = nil
        isConnected = false
        pluginConnected = false
        conversations = []
        openclaws = []
        activeOpenClawId = nil
        messages = [:]
        archivedConversations = []
        mutedConversationIds = []
        searchResults = nil
        pendingApprovals = []
        recentlyArchivedConversation = nil
        typingConversationIds = []
        selectedConversationId = nil
    }

    // MARK: - Conversation operations

    func refreshConversations() async {
        guard let client = bridgeClient else { return }
        isLoadingConversations = true
        defer { isLoadingConversations = false }
        do {
            let resp = try await client.getConversations(openclawInstanceId: activeOpenClawId)
            conversations = sortConversations(resp.conversations)
            loadMutedConversationIds()
            seedSurfacedCreatedConversationIds(from: resp.conversations)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshArchivedConversations() async {
        guard let client = bridgeClient else { return }
        do {
            let resp = try await client.getConversations(archived: true, openclawInstanceId: activeOpenClawId)
            archivedConversations = sortConversations(resp.conversations)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshOpenClaws() async {
        guard let client = bridgeClient else { return }
        do {
            let resp = try await client.getOpenClaws()
            openclaws = resp.openclaws
            if activeOpenClawId == nil || !resp.openclaws.contains(where: { $0.id == activeOpenClawId }) {
                activeOpenClawId = resp.openclaws.first?.id
            }
        } catch {
            openclaws = []
        }
    }

    func switchOpenClaw(to id: String) async {
        guard id != activeOpenClawId else { return }
        activeOpenClawId = id
        messages = [:]
        await refreshConversations()
    }

    func createOpenClaw(name: String) async -> CreateOpenClawResponse? {
        guard let client = bridgeClient else { return nil }
        do {
            let created = try await client.createOpenClaw(name: name)
            openclaws.append(created.openclaw)
            activeOpenClawId = created.openclaw.id
            await refreshConversations()
            return created
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func search(_ query: String) async {
        guard let client = bridgeClient else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = nil
            return
        }
        do {
            searchResults = try await client.search(query: trimmed, openclawInstanceId: activeOpenClawId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func createConversation(
        title: String,
        purpose: String? = nil,
        kind: LPConversation.ConversationKind = .specialist
    ) async -> LPConversation? {
        guard let client = bridgeClient else { return nil }
        do {
            let resp = try await client.createConversation(title: title, purpose: purpose, kind: kind.rawValue, openclawInstanceId: activeOpenClawId)
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
            let archived = conversations.first { $0.id == id }
            _ = try await client.patchConversation(id: id, archived: true)
            conversations.removeAll { $0.id == id }
            recentlyArchivedConversation = archived
            scheduleArchiveUndoDismissal(for: id)
            if selectedConversationId == id { selectedConversationId = nil }
            await refreshArchivedConversations()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func unarchiveConversation(_ id: String) async {
        guard let client = bridgeClient else { return }
        do {
            let resp = try await client.patchConversation(id: id, archived: false)
            archivedConversations.removeAll { $0.id == id }
            if recentlyArchivedConversation?.id == id {
                recentlyArchivedConversation = nil
            }
            applyConversationUpdateOrInsert(resp.conversation)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteConversation(_ id: String) async {
        guard let client = bridgeClient else { return }
        do {
            try await client.deleteConversation(id: id)
            conversations.removeAll { $0.id == id }
            archivedConversations.removeAll { $0.id == id }
            messages.removeValue(forKey: id)
            mutedConversationIds.remove(id)
            if recentlyArchivedConversation?.id == id {
                recentlyArchivedConversation = nil
            }
            saveMutedConversationIds()
            if selectedConversationId == id { selectedConversationId = nil }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setMuted(_ muted: Bool, conversationId: String) {
        if muted {
            mutedConversationIds.insert(conversationId)
        } else {
            mutedConversationIds.remove(conversationId)
        }
        saveMutedConversationIds()
    }

    func isMuted(_ conversationId: String) -> Bool {
        mutedConversationIds.contains(conversationId)
    }

    // MARK: - Push notifications

    func requestPushNotifications() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            guard granted else { return }
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func handleRemoteNotificationToken(_ token: String) {
        pendingApnsToken = token
        Task { await registerPendingPushTokenIfNeeded() }
    }

    // MARK: - Message operations

    func loadMessages(conversationId: String) async {
        guard let client = bridgeClient else { return }
        loadingMessageConversation = conversationId
        defer { loadingMessageConversation = nil }
        do {
            let resp = try await client.getMessages(conversationId: conversationId)
            messages[conversationId] = resp.messages
        } catch {
            lastError = error.localizedDescription
        }
    }

    func unloadMessages(conversationId: String) async {
        messages.removeValue(forKey: conversationId)
    }

    func sendMessage(conversationId: String, text: String, attachments: [PendingAttachment] = []) async {
        guard let client = bridgeClient else { return }
        let tempId = "local-\(UUID().uuidString)"
        let now = ISO8601DateFormatter().string(from: Date())
        let optimisticAttachments = attachments.map { pending in
            LPAttachment(
                id: "local-\(pending.id.uuidString)",
                filename: pending.filename,
                contentType: pending.contentType,
                byteSize: pending.data.count,
                url: nil,
                createdAt: now
            )
        }
        let optimisticMessage = LPMessage(
            id: tempId,
            conversationId: conversationId,
            role: .user,
            content: text,
            status: .sending,
            attachments: optimisticAttachments,
            sourceEventId: nil,
            createdAt: now,
            updatedAt: now
        )
        upsertMessage(optimisticMessage)
        touchConversation(conversationId)

        sendingInConversation = conversationId
        setTyping(true, conversationId: conversationId)
        defer {
            if sendingInConversation == conversationId {
                sendingInConversation = nil
            }
        }
        do {
            var attachmentIds: [String] = []
            for attachment in attachments {
                let uploaded = try await client.uploadAttachment(
                    data: attachment.data,
                    filename: attachment.filename,
                    contentType: attachment.contentType
                )
                attachmentIds.append(uploaded.attachment.id)
            }
            let resp = try await client.sendMessage(conversationId: conversationId, text: text, attachmentIds: attachmentIds)
            replaceMessage(id: tempId, with: resp.message)
            touchConversation(conversationId)
        } catch {
            setTyping(false, conversationId: conversationId)
            updateMessageStatus(id: tempId, conversationId: conversationId, status: .failed)
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
            // SSE envelope nests the actual outbound.message event in `payload`.
            guard
                let inner = payload["payload"] as? [String: Any],
                let convId = inner["conversationId"] as? String,
                let msgData = try? JSONSerialization.data(withJSONObject: inner),
                let event = try? JSONDecoder().decode(OutboundMessagePayload.self, from: msgData)
            else { return }

            let msg = LPMessage(
                id: event.messageId,
                conversationId: convId,
                role: .assistant,
                content: event.text,
                status: event.status == "final" ? .final : .streaming,
                attachments: [],
                sourceEventId: event.id,
                createdAt: event.createdAt ?? ISO8601DateFormatter().string(from: Date()),
                updatedAt: event.createdAt ?? ISO8601DateFormatter().string(from: Date())
            )
            upsertMessage(msg)
            touchConversation(convId)
            setTyping(event.status != "final", conversationId: convId)

        case "outbound.progress":
            if let inner = payload["payload"] as? [String: Any],
               let convId = inner["conversationId"] as? String {
                setTyping(true, conversationId: convId)
            }

        case "outbound.approval.requested":
            guard
                let inner = payload["payload"] as? [String: Any],
                let convId = inner["conversationId"] as? String,
                let approvalId = inner["approvalId"] as? String,
                let title = inner["title"] as? String,
                let eventId = inner["id"] as? String
            else { return }
            pendingApprovals.append(LPApprovalRequest(
                id: eventId, conversationId: convId, approvalId: approvalId,
                title: title, body: inner["body"] as? String,
                expiresAt: inner["expiresAt"] as? String
            ))

        case "conversation.created":
            if let conversation = decodeConversationEvent(payload) {
                applyConversationUpdateOrInsert(conversation)
                if shouldSurfaceCreatedConversation(conversation, eventPayload: payload) {
                    markCreatedConversationSurfaced(conversation.id)
                    newSubagentConversation = conversation
                }
            } else {
                Task { await refreshConversations() }
            }

        case "conversation.updated":
            if let conversation = decodeConversationEvent(payload) {
                if conversation.archivedAt == nil {
                    applyConversationUpdateOrInsert(conversation)
                } else {
                    conversations.removeAll { $0.id == conversation.id }
                    if selectedConversationId == conversation.id { selectedConversationId = nil }
                }
            } else {
                Task { await refreshConversations() }
            }

        case "conversation.deleted":
            let source = (payload["payload"] as? [String: Any]) ?? payload
            if let id = source["id"] as? String {
                conversations.removeAll { $0.id == id }
                archivedConversations.removeAll { $0.id == id }
                messages.removeValue(forKey: id)
                if selectedConversationId == id { selectedConversationId = nil }
            }

        case "plugin.connected":
            pluginConnected = true

        case "plugin.disconnected":
            pluginConnected = false

        default:
            break
        }
    }

    // MARK: - Private helpers

    private func checkStatus() async {
        guard let client = bridgeClient else { return }
        do {
            let status = try await client.getStatus()
            pluginConnected = status.plugin.connected
        } catch {}
    }

    func isTyping(conversationId: String) -> Bool {
        typingConversationIds.contains(conversationId)
    }

    private func setTyping(_ isTyping: Bool, conversationId: String) {
        if isTyping {
            typingConversationIds.insert(conversationId)
            scheduleTypingTimeout(for: conversationId)
        } else {
            typingConversationIds.remove(conversationId)
        }
    }

    private func scheduleTypingTimeout(for conversationId: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            typingConversationIds.remove(conversationId)
        }
    }

    private func scheduleArchiveUndoDismissal(for conversationId: String) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if recentlyArchivedConversation?.id == conversationId {
                recentlyArchivedConversation = nil
            }
        }
    }

    private func registerPendingPushTokenIfNeeded() async {
        guard let client = bridgeClient, let token = pendingApnsToken else { return }
        do {
            let response = try await client.registerPushToken(token, environment: apnsEnvironment)
            if !response.relayConfigured {
                lastError = "Push token saved, but the bridge push relay is not configured."
            }
            pendingApnsToken = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private var apnsEnvironment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
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

    private func replaceMessage(id oldId: String, with newMessage: LPMessage) {
        var list = messages[newMessage.conversationId] ?? []
        if let idx = list.firstIndex(where: { $0.id == oldId }) {
            list[idx] = newMessage
        } else if let idx = list.firstIndex(where: { $0.id == newMessage.id }) {
            list[idx] = newMessage
        } else {
            list.append(newMessage)
        }
        messages[newMessage.conversationId] = list.sorted { $0.createdAt < $1.createdAt }
    }

    private func updateMessageStatus(id: String, conversationId: String, status: LPMessage.MessageStatus) {
        var list = messages[conversationId] ?? []
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        var message = list[idx]
        message.status = status
        message.updatedAt = ISO8601DateFormatter().string(from: Date())
        list[idx] = message
        messages[conversationId] = list
    }

    private func applyConversationUpdate(_ conv: LPConversation) {
        if let idx = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[idx] = conv
        }
    }

    private func applyConversationUpdateOrInsert(_ conv: LPConversation) {
        if let idx = conversations.firstIndex(where: { $0.id == conv.id }) {
            conversations[idx] = conv
        } else {
            conversations.insert(conv, at: 0)
        }
        conversations = sortConversations(conversations)
    }

    private func decodeConversationEvent(_ payload: [String: Any]) -> LPConversation? {
        let source = (payload["payload"] as? [String: Any]) ?? payload
        guard let data = try? JSONSerialization.data(withJSONObject: source) else { return nil }
        return try? JSONDecoder().decode(LPConversation.self, from: data)
    }

    private func shouldSurfaceCreatedConversation(_ conversation: LPConversation, eventPayload: [String: Any]) -> Bool {
        conversation.kind == .subagent
            && !isMuted(conversation.id)
            && !surfacedCreatedConversationIds.contains(conversation.id)
            && isFreshEvent(eventPayload)
    }

    private func isFreshEvent(_ payload: [String: Any]) -> Bool {
        guard let createdAt = payload["createdAt"] as? String,
              let date = parseIsoDate(createdAt)
        else { return false }
        return date >= conversationCreatedNotificationCutoff
    }

    private func parseIsoDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private func touchConversation(_ id: String) {
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            var conv = conversations[idx]
            conv = LPConversation(
                id: conv.id, openclawInstanceId: conv.openclawInstanceId, title: conv.title, purpose: conv.purpose,
                kind: conv.kind, openclawSessionKey: conv.openclawSessionKey,
                openclawAgentId: conv.openclawAgentId, pinned: conv.pinned,
                archivedAt: conv.archivedAt,
                createdAt: conv.createdAt, updatedAt: ISO8601DateFormatter().string(from: Date())
            )
            conversations[idx] = conv
            conversations = sortConversations(conversations)
        }
    }

    private func sortConversations(_ input: [LPConversation]) -> [LPConversation] {
        input.sorted {
            if $0.kind == .main && $1.kind != .main { return true }
            if $1.kind == .main && $0.kind != .main { return false }
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func mutedStorageKey() -> String {
        "muted_conversations_\(activeWorkspaceId?.uuidString ?? "default")"
    }

    private func surfacedCreatedStorageKey() -> String {
        "surfaced_created_conversations_\(activeWorkspaceId?.uuidString ?? "default")"
    }

    private func loadMutedConversationIds() {
        mutedConversationIds = Set(UserDefaults.standard.stringArray(forKey: mutedStorageKey()) ?? [])
    }

    private func saveMutedConversationIds() {
        UserDefaults.standard.set(Array(mutedConversationIds), forKey: mutedStorageKey())
    }

    private func loadSurfacedCreatedConversationIds() {
        surfacedCreatedConversationIds = Set(UserDefaults.standard.stringArray(forKey: surfacedCreatedStorageKey()) ?? [])
    }

    private func markCreatedConversationSurfaced(_ id: String) {
        surfacedCreatedConversationIds.insert(id)
        UserDefaults.standard.set(Array(surfacedCreatedConversationIds), forKey: surfacedCreatedStorageKey())
    }

    private func seedSurfacedCreatedConversationIds(from conversations: [LPConversation]) {
        var changed = false
        for conversation in conversations where conversation.kind == .subagent {
            let createdAt = parseIsoDate(conversation.createdAt)
            guard createdAt == nil || createdAt! < conversationCreatedNotificationCutoff else { continue }
            if surfacedCreatedConversationIds.insert(conversation.id).inserted {
                changed = true
            }
        }
        if changed {
            UserDefaults.standard.set(Array(surfacedCreatedConversationIds), forKey: surfacedCreatedStorageKey())
        }
    }
}

private struct OutboundMessagePayload: Decodable {
    let id: String
    let messageId: String
    let conversationId: String
    let text: String
    let status: String
    let createdAt: String?
}
