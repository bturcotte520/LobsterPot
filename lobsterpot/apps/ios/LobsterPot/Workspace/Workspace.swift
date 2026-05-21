import Foundation

/// A paired OpenClaw Gateway workspace.
///
/// Non-sensitive fields (id, name, gatewayUrl) are persisted in UserDefaults.
/// The gateway shared token and the issued device token are stored in Keychain.
struct Workspace: Identifiable, Codable, Equatable {

    // MARK: - Stored fields (UserDefaults — not sensitive)

    let id: UUID
    var name: String        // User-chosen label, e.g. "KiloClaw"
    var gatewayUrl: String  // wss://hostname:18789

    // MARK: - Keychain-only fields (not in Codable)

    /// The gateway shared token (`gateway.auth.token` value from openclaw.json).
    /// Needed to authenticate the very first connect before a device token is issued.
    var gatewayToken: String

    // MARK: - Codable (excludes gatewayToken — stored in Keychain separately)

    enum CodingKeys: String, CodingKey {
        case id, name, gatewayUrl
    }

    // MARK: - Init

    init(id: UUID = UUID(), name: String, gatewayUrl: String, gatewayToken: String = "") {
        self.id = id
        self.name = name
        self.gatewayUrl = gatewayUrl
        self.gatewayToken = gatewayToken
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        gatewayUrl = try c.decode(String.self, forKey: .gatewayUrl)
        gatewayToken = ""  // hydrated from Keychain by WorkspaceStore.hydrated(_:)
    }

    // MARK: - Derived

    /// Short display name used in the workspace picker avatar.
    var initials: String {
        let words = name.split(separator: " ").map(String.init)
        if words.count >= 2 {
            return String((words[0].first ?? "?")).uppercased()
                 + String((words[1].first ?? "?")).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    /// Normalised URL ensuring the port is present (default 18789).
    var normalizedUrl: String {
        guard var components = URLComponents(string: gatewayUrl) else { return gatewayUrl }
        if components.port == nil { components.port = 18789 }
        return components.string ?? gatewayUrl
    }
}
