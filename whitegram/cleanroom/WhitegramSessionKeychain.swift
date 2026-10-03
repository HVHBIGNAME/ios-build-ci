import Foundation
import Security
import TelegramCore

public struct WhitegramSavedSession {
    public let service: String
    public let id: String
    public let backup: WhitegramSessionBackup?
    public let error: WhitegramSessionError?
}

protocol WhitegramSessionKeychainAccess {
    func read(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
    func add(_ query: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

private struct WhitegramSystemSessionKeychain: WhitegramSessionKeychainAccess {
    func read(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }
    func add(_ query: [String: Any]) -> OSStatus { return SecItemAdd(query as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
    func delete(_ query: [String: Any]) -> OSStatus { return SecItemDelete(query as CFDictionary) }
}

public final class WhitegramSessionKeychain {
    public static let serviceName = "WhitegramSessions"
    private let access: WhitegramSessionKeychainAccess
    private let service: String
    private let legacyServices: [String]

    public init() {
        self.access = WhitegramSystemSessionKeychain()
        self.service = Self.serviceName
        var legacy = ["WhitegramSessions_v2", "Whitegram.sessionsbackup", "ph.telegra.Telegraph.sessionsbackup"]
        if let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty, !legacy.contains(bundleId + ".sessionsbackup") { legacy.append(bundleId + ".sessionsbackup") }
        self.legacyServices = legacy
    }
    init(service: String, legacyServices: [String] = [], access: WhitegramSessionKeychainAccess) { self.service = service; self.legacyServices = legacyServices; self.access = access }

    private func query(id: String? = nil, service: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service ?? self.service, kSecAttrSynchronizable as String: false]
        if let id { query[kSecAttrAccount as String] = id }
        return query
    }

    public func list() throws -> [WhitegramSavedSession] {
        var result: [WhitegramSavedSession] = []
        for service in [service] + legacyServices { result += try list(service: service) }
        guard result.count <= 1000 else { throw WhitegramSessionError.tooLarge }
        return result.sorted { ($0.backup?.date ?? .distantPast) > ($1.backup?.date ?? .distantPast) }
    }

    private func list(service: String) throws -> [WhitegramSavedSession] {
        var query = query(service: service)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        let (status, result) = access.read(query)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw WhitegramSessionError.storage(status) }
        guard let items = result as? [[String: Any]], items.count <= 1000 else { throw WhitegramSessionError.invalidFormat }
        return try items.map { item in
            guard let id = item[kSecAttrAccount as String] as? String, id.utf8.count <= 512 else { throw WhitegramSessionError.invalidFormat }
            guard let data = item[kSecValueData as String] as? Data else { return WhitegramSavedSession(service: service, id: id, backup: nil, error: .invalidFormat) }
            do { return WhitegramSavedSession(service: service, id: id, backup: try WhitegramSessionBackup(data: data), error: nil) }
            catch { return WhitegramSavedSession(service: service, id: id, backup: nil, error: error as? WhitegramSessionError ?? .invalidFormat) }
        }
    }

    public func save(_ backup: WhitegramSessionBackup) throws {
        let id = backup.account.identity.keychainId
        let data = try backup.encoded()
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let query = query(id: id)
        var status = access.update(query, attributes: attributes)
        if status == errSecItemNotFound {
            status = access.add(query.merging(attributes, uniquingKeysWith: { _, new in new }))
            if status == errSecDuplicateItem { status = access.update(query, attributes: attributes) }
        }
        guard status == errSecSuccess else { throw WhitegramSessionError.storage(status) }
        var verification = self.query(id: id)
        verification[kSecMatchLimit as String] = kSecMatchLimitOne
        verification[kSecReturnData as String] = true
        verification[kSecReturnAttributes as String] = true
        let (readStatus, result) = access.read(verification)
        guard readStatus == errSecSuccess else { throw WhitegramSessionError.storage(readStatus) }
        guard let item = result as? [String: Any], item[kSecValueData as String] as? Data == data,
              item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
              item[kSecAttrSynchronizable as String] as? Bool != true else { throw WhitegramSessionError.storageVerification }
    }

    private func retrieveData(id: String, service: String? = nil) throws -> Data {
        if let service, service != self.service, !legacyServices.contains(service) { throw WhitegramSessionError.invalidFormat }
        var query = query(id: id, service: service)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        let (status, result) = access.read(query)
        guard status == errSecSuccess else { throw WhitegramSessionError.storage(status) }
        guard let data = result as? Data else { throw WhitegramSessionError.invalidFormat }
        return data
    }

    public func restore(id: String, service: String? = nil) throws -> WhitegramSessionBackup { return try WhitegramSessionBackup(data: retrieveData(id: id, service: service)) }

    public func delete(id: String, service: String? = nil) throws {
        if let service, service != self.service, !legacyServices.contains(service) { throw WhitegramSessionError.invalidFormat }
        let status = access.delete(query(id: id, service: service))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WhitegramSessionError.storage(status) }
    }

    public func deleteAll() throws {
        for service in [service] + legacyServices {
            let status = access.delete(query(service: service))
            guard status == errSecSuccess || status == errSecItemNotFound else { throw WhitegramSessionError.storage(status) }
        }
    }

    public func diagnostics() -> [(service: String, count: Int, status: Int32)] {
        return ([service] + legacyServices).map { service in
            var query = query(service: service)
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            query[kSecReturnAttributes as String] = true
            let (status, result) = access.read(query)
            return (service, (result as? [[String: Any]])?.count ?? 0, status)
        }
    }
}
