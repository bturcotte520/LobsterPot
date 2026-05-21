import Foundation

/// Persists and manages the list of paired Gateway workspaces.
///
/// Storage strategy:
/// - `[Workspace]` (minus tokens) → UserDefaults under `"workspaces_v1"`
/// - Gateway token → Keychain under `"gw-token-{id}"`
/// - Device token → Keychain under `"workspace-{id}"` (set by `GatewayClient`)
@MainActor
final class WorkspaceStore: ObservableObject {

    // MARK: - Published state

    @Published private(set) var workspaces: [Workspace] = []

    // MARK: - Keys

    static let listKey = "workspaces_v1"

    // MARK: - Init

    init() {
        load()
    }

    // MARK: - CRUD

    func add(_ workspace: Workspace) {
        saveGatewayToken(workspace.gatewayToken, for: workspace.id)
        var ws = workspace
        ws.gatewayToken = ""   // don't persist token in UserDefaults
        workspaces.append(ws)
        persist()
    }

    func update(_ workspace: Workspace) {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        if !workspace.gatewayToken.isEmpty {
            saveGatewayToken(workspace.gatewayToken, for: workspace.id)
        }
        var ws = workspace
        ws.gatewayToken = ""
        workspaces[idx] = ws
        persist()
    }

    func remove(_ workspace: Workspace) {
        workspaces.removeAll { $0.id == workspace.id }
        deleteGatewayToken(for: workspace.id)
        KeychainHelper.delete(service: "com.lobsterpot.app", account: "workspace-\(workspace.id)")
        persist()
    }

    /// Returns the workspace with its gateway token hydrated from Keychain.
    func hydrated(_ workspace: Workspace) -> Workspace {
        var ws = workspace
        ws.gatewayToken = loadGatewayToken(for: workspace.id) ?? ""
        return ws
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.listKey),
              let list = try? JSONDecoder().decode([Workspace].self, from: data)
        else { return }
        workspaces = list
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        UserDefaults.standard.set(data, forKey: Self.listKey)
    }

    // MARK: - Keychain token helpers

    private func saveGatewayToken(_ token: String, for id: UUID) {
        guard !token.isEmpty else { return }
        KeychainHelper.save(token, service: "com.lobsterpot.app", account: "gw-token-\(id)")
    }

    private func loadGatewayToken(for id: UUID) -> String? {
        KeychainHelper.load(service: "com.lobsterpot.app", account: "gw-token-\(id)")
    }

    private func deleteGatewayToken(for id: UUID) {
        KeychainHelper.delete(service: "com.lobsterpot.app", account: "gw-token-\(id)")
    }
}
