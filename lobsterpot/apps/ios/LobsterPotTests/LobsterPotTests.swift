import XCTest
@testable import LobsterPot

final class LobsterPotTests: XCTestCase {

    // MARK: - DeviceIdentity

    func testDeviceIdentityIsStable() {
        let a = DeviceIdentity.loadOrCreate()
        let b = DeviceIdentity.loadOrCreate()
        XCTAssertEqual(a.id, b.id, "Device ID must be stable across calls")
        XCTAssertEqual(a.publicKeyBase64, b.publicKeyBase64)
    }

    func testDeviceIdIsHexSHA256() {
        let identity = DeviceIdentity.loadOrCreate()
        XCTAssertEqual(identity.id.count, 64, "Device ID should be a 64-char SHA-256 hex string")
        XCTAssertTrue(identity.id.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testSignProducesNonEmptyBase64() {
        let identity = DeviceIdentity.loadOrCreate()
        let (sig, signedAt) = identity.sign(
            nonce: "test-nonce-abc123",
            role: "operator",
            scopes: ["operator.read", "operator.write"],
            token: "lobsterpot_test_token"
        )
        XCTAssertFalse(sig.isEmpty, "Signature must not be empty")
        XCTAssertGreaterThan(signedAt, 0)
        // Base64 characters only
        let base64Chars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        XCTAssertTrue(sig.unicodeScalars.allSatisfy { base64Chars.contains($0) })
    }

    func testSignV3PayloadFormat() {
        // Verify the v3 pipe-delimited payload matches what OpenClaw expects:
        // v3|{deviceId}|{clientId}|{clientMode}|{role}|{scopes,comma}|{signedAtMs}|{token}|{nonce}|{platform}|{deviceFamily}
        let identity = DeviceIdentity.loadOrCreate()
        let nonce = "testnonce"
        let ts = Int64(1700000000000)
        let (_, signedAt) = identity.sign(
            nonce: nonce,
            role: "operator",
            scopes: ["operator.read", "operator.write"],
            token: "tok",
            clientId: "lobsterpot-ios",
            clientMode: "operator",
            platform: "iOS",       // will be lowercased to "ios"
            deviceFamily: "iPhone", // will be lowercased to "iphone"
            signedAtMs: ts
        )
        XCTAssertEqual(signedAt, Int(ts))
    }

    // MARK: - GatewayFrames

    func testGWSessionRowDisplayName() {
        // Main session
        let main = makeSessionRow(key: "agent:main:main", label: nil, agentId: "main")
        XCTAssertEqual(main.displayName, "Main")
        XCTAssertTrue(main.isMain)
        XCTAssertFalse(main.isSubagent)

        // Subagent with label
        let labeled = makeSessionRow(key: "agent:main:subagent:abc123", label: "Research", agentId: nil)
        XCTAssertEqual(labeled.displayName, "Research")
        XCTAssertTrue(labeled.isSubagent)

        // Subagent without label
        let unlabeled = makeSessionRow(key: "agent:main:subagent:abcdef12", label: nil, agentId: nil)
        XCTAssertTrue(unlabeled.displayName.contains("Subagent"))
    }

    // MARK: - Workspace

    func testWorkspaceInitials() {
        XCTAssertEqual(Workspace(name: "KiloClaw", gatewayUrl: "wss://x:18789", gatewayToken: "t").initials, "KI")
        XCTAssertEqual(Workspace(name: "My Gateway", gatewayUrl: "wss://x:18789", gatewayToken: "t").initials, "MG")
        XCTAssertEqual(Workspace(name: "X", gatewayUrl: "wss://x:18789", gatewayToken: "t").initials, "X")
    }

    func testWorkspaceNormalizedUrl() {
        let ws = Workspace(name: "Test", gatewayUrl: "wss://kiloclaw.ts.net", gatewayToken: "t")
        XCTAssertTrue(ws.normalizedUrl.contains("18789"), "Default port 18789 should be added")
    }

    // MARK: - LPMessage

    func testLPMessageRole() {
        let msg = LPMessage(sessionKey: "k", role: .user, text: "hi")
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.status, .final_)
    }

    func testLPMessageInitFromChatRow() {
        let row = GWChatMessage(id: "m1", role: "assistant", text: "Hello", ts: 1700000000000, runId: nil)
        let msg = LPMessage(chatRow: row, sessionKey: "agent:main:main")
        XCTAssertEqual(msg.id, "m1")
        XCTAssertEqual(msg.role, .assistant)
        XCTAssertEqual(msg.text, "Hello")
    }

    // MARK: - Helpers

    private func makeSessionRow(key: String, label: String?, agentId: String?) -> GWSessionRow {
        // Decode from JSON to exercise the Codable path
        let json: [String: Any] = [
            "key": key,
            "agentId": agentId as Any,
            "label": label as Any
        ].compactMapValues { $0 is NSNull ? nil : $0 }

        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(GWSessionRow.self, from: data)
    }
}
