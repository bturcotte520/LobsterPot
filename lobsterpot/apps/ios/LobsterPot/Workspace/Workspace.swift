import Foundation
import SwiftUI

/// One bridge connection (one OpenClaw instance). The user can have many.
struct Workspace: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var bridgeUrl: String
    /// Display tint. Indexed enum for stable Codable.
    var colorIndex: Int

    init(id: UUID = UUID(), name: String, bridgeUrl: String, colorIndex: Int = 0) {
        self.id = id
        self.name = name
        self.bridgeUrl = bridgeUrl
        self.colorIndex = colorIndex
    }

    var initials: String {
        let words = name.split(separator: " ").prefix(2)
        return words.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    /// Normalized URL for display (no trailing slash).
    var normalizedUrl: String {
        bridgeUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var color: Color {
        Workspace.palette[colorIndex % Workspace.palette.count]
    }

    static let palette: [Color] = [
        .blue, .purple, .pink, .orange, .green, .teal, .indigo, .red
    ]

    /// Stable Keychain account name for this workspace's device token.
    var keychainAccount: String { "deviceToken-\(id.uuidString)" }
}

/// Persisted list of workspaces (without secrets — tokens live in Keychain).
struct WorkspaceList: Codable {
    var workspaces: [Workspace]
    var activeWorkspaceId: UUID?
}
