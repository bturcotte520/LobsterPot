import XCTest
@testable import LobsterPot

final class LobsterPotTests: XCTestCase {

    // MARK: - BridgeConnection

    func testBridgeConnectionEquality() {
        let a = BridgeConnection(bridgeUrl: "https://bridge.example.com", deviceToken: "device_abc")
        let b = BridgeConnection(bridgeUrl: "https://bridge.example.com", deviceToken: "device_abc")
        XCTAssertEqual(a, b)
    }

    func testBridgeConnectionInequality() {
        let a = BridgeConnection(bridgeUrl: "https://bridge.example.com", deviceToken: "device_abc")
        let b = BridgeConnection(bridgeUrl: "https://other.example.com", deviceToken: "device_abc")
        XCTAssertNotEqual(a, b)
    }

    func testBridgeConnectionStorageKeys() {
        // Verify the storage key constants are stable; changing them would break
        // existing installations that already have data persisted under these keys.
        XCTAssertEqual(BridgeConnection.urlStorageKey, "bridge_url_v1")
        XCTAssertEqual(BridgeConnection.keychainService, "com.lobsterpot.app")
        XCTAssertEqual(BridgeConnection.keychainAccount, "deviceToken")
    }

    // MARK: - LPConversation

    func testConversationDecodeFromJSON() throws {
        let json = """
        {
          "id": "550e8400-e29b-41d4-a716-446655440000",
          "title": "My Conversation",
          "purpose": "Research questions",
          "kind": "specialist",
          "pinned": false,
          "archivedAt": null,
          "createdAt": "2026-01-01T00:00:00.000Z",
          "updatedAt": "2026-01-01T00:00:00.000Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let conv = try decoder.decode(LPConversation.self, from: json)

        XCTAssertEqual(conv.id, "550e8400-e29b-41d4-a716-446655440000")
        XCTAssertEqual(conv.title, "My Conversation")
        XCTAssertEqual(conv.kind, .specialist)
        XCTAssertFalse(conv.pinned)
    }

    func testConversationKindAllCases() {
        let kinds: [LPConversation.ConversationKind] = [.main, .specialist, .support, .system]
        XCTAssertEqual(kinds.count, 4)
        for kind in kinds {
            let encoded = try? JSONEncoder().encode(kind)
            XCTAssertNotNil(encoded)
        }
    }

    // MARK: - LPMessage

    func testMessageDecodeFromJSON() throws {
        let json = """
        {
          "id": "msg-001",
          "conversationId": "conv-001",
          "role": "assistant",
          "content": "Hello!",
          "status": "final",
          "sourceEventId": null,
          "createdAt": "2026-01-01T00:00:00.000Z",
          "updatedAt": "2026-01-01T00:00:00.000Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let msg = try decoder.decode(LPMessage.self, from: json)

        XCTAssertEqual(msg.id, "msg-001")
        XCTAssertEqual(msg.role, .assistant)
        XCTAssertEqual(msg.status, .final)
        XCTAssertNil(msg.sourceEventId)
    }

    func testMessageStatusAllCases() {
        let statuses: [LPMessage.MessageStatus] = [.queued, .sending, .sent, .streaming, .final, .failed, .cancelled]
        XCTAssertEqual(statuses.count, 7)
    }

    func testMessageRoleAllCases() {
        let roles: [LPMessage.MessageRole] = [.user, .assistant, .system, .tool]
        XCTAssertEqual(roles.count, 4)
    }

    // MARK: - ConversationListResponse

    func testConversationListResponseDecode() throws {
        let json = """
        {
          "conversations": [
            {
              "id": "1", "title": "A",
              "kind": "main", "pinned": true,
              "createdAt": "2026-01-01T00:00:00.000Z",
              "updatedAt": "2026-01-01T00:00:00.000Z"
            }
          ]
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let resp = try decoder.decode(ConversationListResponse.self, from: json)
        XCTAssertEqual(resp.conversations.count, 1)
        XCTAssertEqual(resp.conversations[0].title, "A")
        XCTAssertTrue(resp.conversations[0].pinned)
    }

    // MARK: - BridgeStatusResponse

    func testBridgeStatusResponseDecode() throws {
        let json = """
        {
          "ok": true,
          "service": "lobsterpot-bridge",
          "plugin": {
            "connected": false,
            "status": "waiting",
            "instanceId": null,
            "lastSeenAt": null,
            "capabilities": []
          },
          "now": "2026-01-01T00:00:00.000Z"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let status = try decoder.decode(BridgeStatusResponse.self, from: json)
        XCTAssertTrue(status.ok)
        XCTAssertFalse(status.plugin.connected)
        XCTAssertEqual(status.plugin.status, "waiting")
    }

    // MARK: - TokenResponse

    func testTokenResponseDecode() throws {
        let json = """
        {"id":"tok-1","token":"lobsterpot_abc","createdAt":"2026-01-01T00:00:00.000Z"}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let token = try decoder.decode(TokenResponse.self, from: json)
        XCTAssertEqual(token.token, "lobsterpot_abc")
        XCTAssertTrue(token.token.hasPrefix("lobsterpot_"))
    }
}
