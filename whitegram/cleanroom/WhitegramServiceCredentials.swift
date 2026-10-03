import Foundation
import CoreFoundation
#if canImport(Security) && canImport(TelegramCore)
import Security
import TelegramCore
#endif

public enum WhitegramServiceCredential: String, CaseIterable {
    case gemini = "geminiApiKey"
    case groq = "groqApiKey"
    case virusTotal = "virusTotalApiKey"

    public static let updatedNotification = Notification.Name("WhitegramServiceCredentialUpdated")
}

protocol WhitegramServiceSecretStorage: AnyObject {
    func read(_ credential: WhitegramServiceCredential) throws -> String?
    func write(_ value: String, for credential: WhitegramServiceCredential) throws
    func remove(_ credential: WhitegramServiceCredential) throws
}

protocol WhitegramServiceLegacyCredentialStorage: AnyObject {
    func read(_ credential: WhitegramServiceCredential) throws -> String?
    func clear(_ credential: WhitegramServiceCredential) throws
}

// This migration policy is Foundation-only so failure ordering can be tested without a Keychain host.
final class WhitegramServiceCredentialVault: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let secrets: WhitegramServiceSecretStorage
    private let legacy: WhitegramServiceLegacyCredentialStorage

    init(secrets: WhitegramServiceSecretStorage, legacy: WhitegramServiceLegacyCredentialStorage) {
        self.secrets = secrets
        self.legacy = legacy
    }

    func token(for credential: WhitegramServiceCredential) throws -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        if let stored = try self.secrets.read(credential) {
            let value = try whitegramValidatedAPIKey(stored)
            try self.legacy.clear(credential)
            return value
        }
        guard let legacy = try self.legacy.read(credential), !legacy.isEmpty else { return nil }
        let value = try whitegramValidatedAPIKey(legacy)
        try self.secrets.write(value, for: credential)
        try self.legacy.clear(credential)
        return value
    }

    func save(_ value: String, for credential: WhitegramServiceCredential) throws {
        do {
            self.lock.lock()
            defer { self.lock.unlock() }
            try self.secrets.write(whitegramValidatedAPIKey(value), for: credential)
            try self.legacy.clear(credential)
        }
        NotificationCenter.default.post(name: WhitegramServiceCredential.updatedNotification, object: credential)
    }

    func remove(_ credential: WhitegramServiceCredential) throws {
        do {
            self.lock.lock()
            defer { self.lock.unlock() }
            // Clear plaintext first: a failed Keychain delete must not resurrect a legacy value.
            try self.legacy.clear(credential)
            try self.secrets.remove(credential)
        }
        NotificationCenter.default.post(name: WhitegramServiceCredential.updatedNotification, object: credential)
    }
}

#if canImport(Security) && canImport(TelegramCore)
private final class WhitegramServiceKeychainStorage: WhitegramServiceSecretStorage {
    private let service = (Bundle.main.bundleIdentifier ?? "Whitegram") + ".Whitegram.Services.v1"

    private func query(_ credential: WhitegramServiceCredential) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: credential.rawValue,
            kSecAttrSynchronizable as String: false
        ]
    }

    func read(_ credential: WhitegramServiceCredential) throws -> String? {
        var query = self.query(credential)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw WhitegramServiceError.keychain(status: Int(status)) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw WhitegramServiceError.keychain(status: Int(errSecDecode))
        }
        return value
    }

    func write(_ value: String, for credential: WhitegramServiceCredential) throws {
        let query = self.query(credential)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw WhitegramServiceError.keychain(status: Int(status)) }
    }

    func remove(_ credential: WhitegramServiceCredential) throws {
        let status = SecItemDelete(self.query(credential) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw WhitegramServiceError.keychain(status: Int(status)) }
    }
}

private final class WhitegramServicePreferenceCredentials: WhitegramServiceLegacyCredentialStorage {
    private let defaults = UserDefaults.standard
    private let legacyStorageKey = "WhitegramPrivacySettings.v1"

    private func legacyValues() throws -> [String: Any] {
        guard let data = self.defaults.data(forKey: self.legacyStorageKey) else { return [:] }
        do {
            guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WhitegramServiceError.preferences }
            return values
        } catch {
            throw WhitegramServiceError.preferences
        }
    }

    func read(_ credential: WhitegramServiceCredential) throws -> String? {
        let key = credential.rawValue
        let values = [WhitegramPreferences.string(key), self.defaults.string(forKey: "wg_" + key) ?? "", self.defaults.string(forKey: key) ?? ""]
        if let value = values.first(where: { !$0.isEmpty }) { return value }
        return try self.legacyValues()[key] as? String
    }

    func clear(_ credential: WhitegramServiceCredential) throws {
        let key = credential.rawValue
        var legacy = try self.legacyValues()
        if legacy.removeValue(forKey: key) != nil {
            do {
                self.defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: self.legacyStorageKey)
            } catch {
                throw WhitegramServiceError.preferences
            }
        }
        let hasValue = !WhitegramPreferences.string(key).isEmpty || !(self.defaults.string(forKey: "wg_" + key) ?? "").isEmpty || !(self.defaults.string(forKey: key) ?? "").isEmpty
        if hasValue {
            // Remove direct copies before update() publishes its synchronous notification.
            self.defaults.removeObject(forKey: "wg_" + key)
            self.defaults.removeObject(forKey: key)
            guard WhitegramPreferences.set("", for: key) else { throw WhitegramServiceError.preferences }
            self.defaults.removeObject(forKey: "wg_" + key)
        }
    }
}

enum WhitegramServiceCredentials {
    static let vault = WhitegramServiceCredentialVault(secrets: WhitegramServiceKeychainStorage(), legacy: WhitegramServicePreferenceCredentials())
}

extension WhitegramServiceRoute {
    static var configuredVirusTotal: WhitegramServiceRoute {
        let value = WhitegramPreferences.values()["virusTotalUseProxy"] ?? UserDefaults.standard.object(forKey: "wg_virusTotalUseProxy")
        // The original VirusTotal manager always used Whitegram's signed proxy.
        // This new flag permits an explicit Direct API choice without silently changing that route.
        return self.fromProxyFlag(value)
    }
}

/// Call at app startup and before a settings export to migrate legacy API tokens.
/// The returned failures contain fixed errors only. A failed migration never falls back to a plaintext request.
public func whitegramMigrateServiceCredentials() -> [WhitegramServiceCredential: WhitegramServiceError] {
    var failures: [WhitegramServiceCredential: WhitegramServiceError] = [:]
    for credential in WhitegramServiceCredential.allCases {
        do {
            _ = try WhitegramServiceCredentials.vault.token(for: credential)
        } catch let error as WhitegramServiceError {
            failures[credential] = error
        } catch {
            failures[credential] = .preferences
        }
    }
    return failures
}

extension WhitegramAIProvider {
    var credential: WhitegramServiceCredential { return self == .gemini ? .gemini : .groq }
    var modelPreference: String { return self == .gemini ? "geminiModelId" : "groqModelId" }
    var proxyPreference: String { return self == .gemini ? "geminiUseProxy" : "groqUseProxy" }

    var configuredModel: String {
        return self.modelId(storedValue: WhitegramPreferences.values()[self.modelPreference] ?? UserDefaults.standard.object(forKey: "wg_" + self.modelPreference))
    }

    var configuredRoute: WhitegramServiceRoute {
        let value = WhitegramPreferences.values()[self.proxyPreference] ?? UserDefaults.standard.object(forKey: "wg_" + self.proxyPreference)
        // Both original getters default to true. An explicit false selects the direct API.
        return .fromProxyFlag(value)
    }

    static var configured: WhitegramAIProvider? {
        let value = WhitegramPreferences.values()["aiProvider"] ?? UserDefaults.standard.object(forKey: "wg_aiProvider")
        guard let value else { return .gemini }
        return (value as? String).flatMap { WhitegramAIProvider(rawValue: $0.lowercased()) }
    }
}

/// Uses the enabled provider/model and its Keychain credential. The caller must obtain explicit submission intent.
@discardableResult
public func whitegramGenerateAIText(_ text: String, completion: @escaping (Result<WhitegramAIResponse, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
    do {
        guard WhitegramPreferences.bool("geminiEnabled") else { throw WhitegramServiceError.disabled }
        guard let provider = WhitegramAIProvider.configured else { throw WhitegramServiceError.invalidProvider }
        guard let key = try WhitegramServiceCredentials.vault.token(for: provider.credential) else { throw WhitegramServiceError.missingAPIKey }
        return WhitegramAIService.shared.generate(text: text, provider: provider, model: provider.configuredModel, apiKey: key, route: provider.configuredRoute, completion: completion)
    } catch {
        let operation = WhitegramServiceOperation(completion: completion)
        operation.finish(.failure(error as? WhitegramServiceError ?? .preferences))
        return operation.task
    }
}

/// Looks up only this explicitly supplied hash, using the enabled setting and Keychain credential.
@discardableResult
public func whitegramLookupVirusTotalHash(_ sha256: String, completion: @escaping (Result<WhitegramVirusTotalLookupResult, WhitegramServiceError>) -> Void) -> WhitegramServiceTask {
    do {
        guard WhitegramPreferences.bool("virusTotalEnabled") else { throw WhitegramServiceError.disabled }
        try WhitegramServiceRoute.configuredVirusTotal.requireAvailable()
        guard let key = try WhitegramServiceCredentials.vault.token(for: .virusTotal) else { throw WhitegramServiceError.missingAPIKey }
        return WhitegramVirusTotalService.shared.lookup(sha256: sha256, apiKey: key, completion: completion)
    } catch {
        let operation = WhitegramServiceOperation(completion: completion)
        operation.finish(.failure(error as? WhitegramServiceError ?? .preferences))
        return operation.task
    }
}
#endif
