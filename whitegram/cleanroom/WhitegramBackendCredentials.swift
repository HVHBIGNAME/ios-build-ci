import Foundation
import Security

protocol WhitegramBackendSessionStorage: AnyObject {
    func load(userId: Int64) throws -> WhitegramBackendSession?
    func save(_ session: WhitegramBackendSession) throws
    func remove(userId: Int64) throws
    func remove(userId: Int64, matching session: WhitegramBackendSession) throws -> Bool
}

final class WhitegramBackendKeychain: WhitegramBackendSessionStorage {
    static let shared = WhitegramBackendKeychain()
    private let lock = NSRecursiveLock()
    private let service: String
    private let legacyDeviceTokenService: String?

    init(service: String = "com.whitegram.backend.sessions.v1", legacyDeviceTokenService: String? = "com.whitegram.deviceToken") {
        self.service = service
        self.legacyDeviceTokenService = legacyDeviceTokenService
    }

    private func query(_ account: String) -> [String: Any] {
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    private func read(_ account: String, service: String? = nil) throws -> Data? {
        var query = self.query(account)
        if let service { query[kSecAttrService as String] = service }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw WhitegramBackendError.keychain(status) }
        guard let data = result as? Data else { throw WhitegramBackendError.invalidResponse }
        return data
    }

    private func write(_ data: Data, account: String) throws {
        let query = self.query(account)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw WhitegramBackendError.keychain(status) }
    }

    func load(userId: Int64) throws -> WhitegramBackendSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try read("session.\(userId)") else { return nil }
        let session = try JSONDecoder().decode(WhitegramBackendSession.self, from: data)
        guard session.userId == userId else { throw WhitegramBackendError.accountMismatch }
        return session
    }

    func save(_ session: WhitegramBackendSession) throws {
        lock.lock()
        defer { lock.unlock() }
        try session.validate(userId: session.userId, now: Date())
        try write(JSONEncoder().encode(session), account: "session.\(session.userId)")
    }

    func remove(userId: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        let status = SecItemDelete(query("session.\(userId)") as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WhitegramBackendError.keychain(status) }
    }

    func remove(userId: Int64, matching session: WhitegramBackendSession) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard try load(userId: userId) == session else { return false }
        try remove(userId: userId)
        return true
    }

    func deviceToken() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let data = try read("device-token") {
            guard let token = String(data: data, encoding: .utf8), !token.isEmpty, token.utf8.count <= 1024 else { throw WhitegramBackendError.deviceIdentity }
            return token
        }
        if let legacyDeviceTokenService, let data = try read("wg_stableDeviceToken", service: legacyDeviceTokenService) {
            guard let token = String(data: data, encoding: .utf8), !token.isEmpty, token.utf8.count <= 1024 else { throw WhitegramBackendError.deviceIdentity }
            try write(data, account: "device-token")
            guard try read("device-token") == data else { throw WhitegramBackendError.deviceIdentity }
            return token
        }
        let token = UserDefaults.standard.string(forKey: "wg_stableDeviceToken") ?? UUID().uuidString
        guard !token.isEmpty, token.utf8.count <= 1024 else { throw WhitegramBackendError.deviceIdentity }
        try write(Data(token.utf8), account: "device-token")
        return token
    }
}

final class WhitegramBackendIdentity {
    static let shared = WhitegramBackendIdentity()
    private let lock = NSLock()
    private let tag: Data
    private var cachedKey: SecKey?

    init(tag: String = "com.whitegram.deviceIdentity.p256") { self.tag = Data(tag.utf8) }

    private func key() throws -> SecKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecReturnRef as String: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            guard let item, CFGetTypeID(item) == SecKeyGetTypeID() else { throw WhitegramBackendError.deviceIdentity }
            let key = item as! SecKey
            cachedKey = key
            return key
        }
        guard status == errSecItemNotFound else { throw WhitegramBackendError.keychain(status) }
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            _ = error?.takeRetainedValue()
            throw WhitegramBackendError.deviceIdentity
        }
        cachedKey = key
        return key
    }

    func publicKeyBase64() throws -> String {
        guard let publicKey = SecKeyCopyPublicKey(try key()), let data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw WhitegramBackendError.deviceIdentity
        }
        return data.base64EncodedString()
    }

    func sign(_ message: String) throws -> String? {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(try key(), .ecdsaSignatureMessageX962SHA256, Data(message.utf8) as CFData, &error) as Data? else {
            _ = error?.takeRetainedValue()
            throw WhitegramBackendError.deviceIdentity
        }
        return signature.base64EncodedString()
    }
}
