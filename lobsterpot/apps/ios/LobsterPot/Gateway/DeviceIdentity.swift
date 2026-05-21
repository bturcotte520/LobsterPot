import Foundation
import CryptoKit

/// Manages the app's stable Ed25519 device identity.
///
/// The keypair is generated once and persisted in the Keychain. The device ID is the
/// SHA-256 hex of the public key raw bytes — this is what OpenClaw uses as the
/// stable device fingerprint across reconnects.
final class DeviceIdentity {

    // MARK: - Properties

    /// SHA-256 hex fingerprint of the raw public key bytes.
    /// Used as `device.id` in the connect request and for `openclaw devices approve`.
    let id: String

    /// Base64-encoded raw public key (32 bytes) — sent as `device.publicKey`.
    let publicKeyBase64: String

    private let privateKey: Curve25519.Signing.PrivateKey

    // MARK: - Keychain storage keys

    static let keychainService = "com.lobsterpot.app"
    static let keychainAccount = "deviceSigningKey"

    // MARK: - Factory

    /// Loads the existing keypair from Keychain, or generates and persists a new one.
    static func loadOrCreate() -> DeviceIdentity {
        if let stored = KeychainHelper.load(service: keychainService, account: keychainAccount),
           let keyData = Data(base64Encoded: stored),
           let privKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) {
            return DeviceIdentity(privateKey: privKey)
        }
        let newKey = Curve25519.Signing.PrivateKey()
        let encoded = newKey.rawRepresentation.base64EncodedString()
        KeychainHelper.save(encoded, service: keychainService, account: keychainAccount)
        return DeviceIdentity(privateKey: newKey)
    }

    private init(privateKey: Curve25519.Signing.PrivateKey) {
        self.privateKey = privateKey
        let pubBytes = privateKey.publicKey.rawRepresentation
        let digest = SHA256.hash(data: pubBytes)
        self.id = digest.map { String(format: "%02x", $0) }.joined()
        self.publicKeyBase64 = pubBytes.base64EncodedString()
    }

    // MARK: - Signing

    /// Builds and signs the v3 device auth payload for a `connect` request.
    ///
    /// v3 payload (pipe-delimited, per `src/gateway/device-auth.ts`):
    /// ```
    /// v3|{deviceId}|{clientId}|{clientMode}|{role}|{scopes,comma}|{signedAtMs}|{token}|{nonce}|{platform_lower}|{deviceFamily_lower}
    /// ```
    ///
    /// - Returns: Base64-encoded Ed25519 signature.
    func sign(
        nonce: String,
        role: String,
        scopes: [String],
        token: String?,
        clientId: String = "lobsterpot-ios",
        clientMode: String = "operator",
        platform: String = "ios",
        deviceFamily: String = "iphone",
        signedAtMs: Int64? = nil
    ) -> (signature: String, signedAt: Int) {
        let ts = signedAtMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let scopesStr = scopes.joined(separator: ",")
        let tokenStr = token ?? ""

        // normalizeDeviceMetadataForAuth = trim + ASCII lowercase
        let normalizedPlatform = platform.trimmingCharacters(in: .whitespaces).lowercased()
        let normalizedFamily = deviceFamily.trimmingCharacters(in: .whitespaces).lowercased()

        let payload = [
            "v3",
            id,
            clientId,
            clientMode,
            role,
            scopesStr,
            "\(ts)",
            tokenStr,
            nonce,
            normalizedPlatform,
            normalizedFamily
        ].joined(separator: "|")

        let payloadData = Data(payload.utf8)
        let sig = (try? privateKey.signature(for: payloadData)) ?? Data()
        return (sig.base64EncodedString(), Int(ts))
    }
}
