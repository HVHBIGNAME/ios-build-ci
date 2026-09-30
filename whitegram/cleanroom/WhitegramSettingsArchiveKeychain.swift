import Foundation
import TelegramCore
#if canImport(Security)
import Security
#endif

public enum WhitegramSettingsArchiveKeychainError: Error, LocalizedError {
    case missing, unavailable, invalidItem, verificationFailed, status(Int32)

    public var errorDescription: String? {
        switch self {
        case .missing: return "No Whitegram port settings backup is saved in this device's Keychain."
        case .unavailable: return "Settings Keychain backup is unavailable on this platform."
        case .invalidItem: return "The Keychain item has an unsupported format or protection policy."
        case .verificationFailed: return "The Keychain write could not be verified. The backup was not reported as saved."
        case let .status(code):
            if code == -25308 { return "Unlock the device and try the Keychain operation again." }
            return "Keychain operation failed (OSStatus \(code))."
        }
    }
}

#if canImport(Security)
protocol WhitegramSettingsArchiveKeychainAccess {
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func read(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
}

private struct WhitegramSettingsArchiveSystemKeychain: WhitegramSettingsArchiveKeychainAccess {
    func add(_ attributes: [String: Any]) -> OSStatus { return SecItemAdd(attributes as CFDictionary, nil) }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus { return SecItemUpdate(query as CFDictionary, attributes as CFDictionary) }
    func read(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item)
    }
}
public final class WhitegramSettingsArchiveKeychain {
    private let access: WhitegramSettingsArchiveKeychainAccess
    private let service: String
    private let lock = NSLock()

    public init() {
        self.service = (Bundle.main.bundleIdentifier ?? "Whitegram") + ".Whitegram.SettingsArchive.v1"
        self.access = WhitegramSettingsArchiveSystemKeychain()
    }

    init(service: String, access: WhitegramSettingsArchiveKeychainAccess) {
        self.service = service
        self.access = access
    }

    private var query: [String: Any] {
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: "settings-v1", kSecAttrSynchronizable as String: false]
    }

    public func save(_ archive: WhitegramSettingsArchive) throws {
        let data = try archive.encoded()
        // Re-validate before storing even a programmatically obtained archive.
        _ = try WhitegramSettingsArchive(data: data)
        lock.lock()
        defer { lock.unlock() }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false]
        let status = access.add(query.merging(attributes, uniquingKeysWith: { _, new in new }))
        let finalStatus = status == errSecDuplicateItem ? access.update(query, attributes: attributes) : status
        guard finalStatus == errSecSuccess else { throw WhitegramSettingsArchiveKeychainError.status(finalStatus) }
        guard try readData() == data else { throw WhitegramSettingsArchiveKeychainError.verificationFailed }
    }

    public func restore() throws -> WhitegramSettingsArchive {
        lock.lock()
        defer { lock.unlock() }
        return try WhitegramSettingsArchive(data: readData())
    }

    private func readData() throws -> Data {
        let options: [String: Any] = [kSecReturnData as String: true, kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        let (status, item) = access.read(query.merging(options, uniquingKeysWith: { _, new in new }))
        if status == errSecItemNotFound { throw WhitegramSettingsArchiveKeychainError.missing }
        guard status == errSecSuccess else { throw WhitegramSettingsArchiveKeychainError.status(status) }
        guard let attributes = item as? [String: Any], let data = attributes[kSecValueData as String] as? Data,
              (attributes[kSecAttrAccessible as String] as? String) == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String),
              (attributes[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue != true else {
            throw WhitegramSettingsArchiveKeychainError.invalidItem
        }
        guard data.count <= WhitegramSettingsArchive.maximumBytes else { throw WhitegramSettingsArchiveError.tooLarge }
        return data
    }
}
#else
public final class WhitegramSettingsArchiveKeychain {
    public init() {}
    public func save(_ archive: WhitegramSettingsArchive) throws { throw WhitegramSettingsArchiveKeychainError.unavailable }
    public func restore() throws -> WhitegramSettingsArchive { throw WhitegramSettingsArchiveKeychainError.unavailable }
}
#endif
