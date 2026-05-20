import XCTest
@testable import LobsterPot

final class LobsterPotTests: XCTestCase {

    func testBridgeConnectionEquality() {
        let a = BridgeConnection(bridgeUrl: "https://bridge.example.com", deviceToken: "device_abc")
        let b = BridgeConnection(bridgeUrl: "https://bridge.example.com", deviceToken: "device_abc")
        XCTAssertEqual(a, b)
    }

    func testBridgeConnectionPersistRoundtrip() throws {
        let conn = BridgeConnection(bridgeUrl: "https://bridge.example.com", deviceToken: "device_abc")
        let data = try JSONEncoder().encode(conn)
        let decoded = try JSONDecoder().decode(BridgeConnection.self, from: data)
        XCTAssertEqual(conn, decoded)
    }
}
