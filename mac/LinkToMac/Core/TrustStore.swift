import CryptoKit
import Foundation
import Security

/// The phone this Mac is paired with. Contains only public data.
struct PairedDevice: Codable, Equatable {
    var name: String
    var model: String
    var certFingerprint: String
    var lastHost: String?
    var port: Int
}

/// Keychain access for the Mac's private signing key, plus storage of the paired phone.
final class TrustStore {
    static let shared = TrustStore()

    private let service = "de.linktomac.identity"
    private let account = "p256-signing-key"
    private let deviceKey = "pairedDevice"

    private(set) lazy var signingKey: P256.Signing.PrivateKey = loadOrCreateKey()

    var publicKeyDER: Data { signingKey.publicKey.derRepresentation }
    var keyFingerprint: String { Data(SHA256.hash(data: publicKeyDER)).hexString }

    // MARK: Paired device

    var pairedDevice: PairedDevice? {
        get {
            guard let data = UserDefaults.standard.data(forKey: deviceKey) else { return nil }
            return try? JSONDecoder().decode(PairedDevice.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: deviceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: deviceKey)
            }
        }
    }

    // MARK: Signing

    func sign(_ message: Data) throws -> Data {
        try signingKey.signature(for: message).derRepresentation
    }

    /// Creates a new identity (used when unpairing so a new QR code is a fresh trust anchor).
    func resetIdentity() {
        deleteKeychainItem()
        try? FileManager.default.removeItem(at: fallbackURL)
        signingKey = loadOrCreateKey()
    }

    // MARK: Keychain

    private func loadOrCreateKey() -> P256.Signing.PrivateKey {
        if let raw = readKeychainItem() ?? (try? Data(contentsOf: fallbackURL)),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            return key
        }
        let key = P256.Signing.PrivateKey()
        if !writeKeychainItem(key.rawRepresentation) {
            // Fallback for unsigned builds where the keychain is not available:
            // a file inside the sandbox container, readable only by this user.
            try? FileManager.default.createDirectory(at: fallbackURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? key.rawRepresentation.write(to: fallbackURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallbackURL.path)
        }
        return key
    }

    private var fallbackURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LinkToMac/identity.key")
    }

    private func readKeychainItem() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess else { return nil }
        return out as? Data
    }

    private func writeKeychainItem(_ data: Data) -> Bool {
        deleteKeychainItem()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Link to Mac – Kopplungsschlüssel",
            kSecValueData as String: data,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private func deleteKeychainItem() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum AuthCrypto {
    static func authMessage(challenge: String, certFingerprint: String) -> Data {
        Data("linktomac-auth|\(challenge)|\(certFingerprint)".utf8)
    }

    static func pairingProof(token: Data, certFingerprint: String, keyFingerprint: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("\(certFingerprint)|\(keyFingerprint)".utf8),
            using: SymmetricKey(data: token)
        )
        return Data(mac).base64EncodedString()
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}
