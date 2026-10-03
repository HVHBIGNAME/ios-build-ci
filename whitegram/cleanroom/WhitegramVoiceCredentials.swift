import Foundation
import Security

public enum WhitegramVoiceCredentials {
    private static let service = "Whitegram.Voice.ElevenLabs"
    private static let account = "api-key"

    public static func read() throws -> String? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, let text = String(data: data, encoding: .utf8) else {
            throw WhitegramVoiceProcessingError.credentialStore(status)
        }
        return text
    }

    public static func save(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains("\r"), !value.contains("\n") else { throw WhitegramVoiceProcessingError.invalidCredential }
        if value.isEmpty {
            let status = SecItemDelete(self.query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw WhitegramVoiceProcessingError.credentialStore(status) }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(self.query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(self.query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw WhitegramVoiceProcessingError.credentialStore(status) }
    }

    private static var query: [String: Any] {
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: self.service, kSecAttrAccount as String: self.account]
    }
}
