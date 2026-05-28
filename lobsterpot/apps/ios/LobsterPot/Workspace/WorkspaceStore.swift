import Foundation

/// Persistent store for workspaces. List metadata in UserDefaults, tokens in Keychain.
@MainActor
final class WorkspaceStore: ObservableObject {

    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var activeWorkspaceId: UUID?

    private static let listStorageKey = "workspace_list_v1"
    private static let keychainService = "com.lobsterpot.app"

    init() {
        load()
    }

    // MARK: - CRUD

    func add(_ workspace: Workspace, deviceToken: String) {
        workspaces.append(workspace)
        if activeWorkspaceId == nil { activeWorkspaceId = workspace.id }
        KeychainHelper.save(deviceToken, service: Self.keychainService, account: workspace.keychainAccount)
        persist()
    }

    func remove(_ id: UUID) {
        if let ws = workspaces.first(where: { $0.id == id }) {
            KeychainHelper.delete(service: Self.keychainService, account: ws.keychainAccount)
        }
        workspaces.removeAll { $0.id == id }
        if activeWorkspaceId == id {
            activeWorkspaceId = workspaces.first?.id
        }
        persist()
    }

    func setActive(_ id: UUID) {
        guard workspaces.contains(where: { $0.id == id }) else { return }
        activeWorkspaceId = id
        persist()
    }

    func update(_ workspace: Workspace) {
        if let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[idx] = workspace
            persist()
        }
    }

    var activeWorkspace: Workspace? {
        guard let id = activeWorkspaceId else { return nil }
        return workspaces.first { $0.id == id }
    }

    func deviceToken(for workspaceId: UUID) -> String? {
        guard let ws = workspaces.first(where: { $0.id == workspaceId }) else { return nil }
        return KeychainHelper.load(service: Self.keychainService, account: ws.keychainAccount)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.listStorageKey),
              let decoded = try? JSONDecoder().decode(WorkspaceList.self, from: data) else {
            workspaces = []
            activeWorkspaceId = nil
            return
        }
        workspaces = decoded.workspaces
        activeWorkspaceId = decoded.activeWorkspaceId ?? decoded.workspaces.first?.id
    }

    private func persist() {
        let list = WorkspaceList(workspaces: workspaces, activeWorkspaceId: activeWorkspaceId)
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.listStorageKey)
        }
    }
}
