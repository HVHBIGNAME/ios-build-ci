import Foundation

public enum WhitegramSessionError: Error, Equatable, LocalizedError {
    case invalidFormat, invalidKey, invalidDatacenter, missingIdentity, identityMismatch
    case tooLarge, unreadable, changedFile, unsafeFile, encryptedSession, encryptedArchive
    case passcodeRequired, invalidPasscode, damagedTData, unsupportedTData
    case duplicateIdentity, conflictingSessions, unavailable, cancelled, timeout, storage(Int32), storageVerification
    case authorizationRejected, tokenInvalid, tokenExpired, passwordRequired, floodWait(Int32), network

    public var errorDescription: String? {
        switch self {
        case .invalidFormat: return "The session format is invalid or unsupported."
        case .invalidKey: return "A session must contain a valid 256-byte MTProto authorization key."
        case .invalidDatacenter: return "The session's Telegram data center is invalid."
        case .missingIdentity: return "The session has no user ID. Include its matching JSON sidecar."
        case .identityMismatch: return "Telegram returned a different account identity. The import was rejected."
        case .tooLarge: return "The selected session files exceed the import limit."
        case .unreadable: return "The session file could not be read. Download it in Files and try again."
        case .changedFile: return "A session file changed while being read. Close its source client and try again."
        case .unsafeFile: return "Choose regular session files or a tdata folder without symbolic links."
        case .encryptedSession: return "This is not a plaintext Telethon SQLite session. Encrypted SQLite sessions require their original export tool."
        case .encryptedArchive: return "This ZIP archive is password-protected. Unlock it locally before importing its session files."
        case .passcodeRequired: return "This tdata folder requires its Telegram Desktop local passcode."
        case .invalidPasscode: return "The tdata passcode is incorrect, or the encrypted key is damaged."
        case .damagedTData: return "The tdata checksum, encrypted payload, or account data is damaged."
        case .unsupportedTData: return "This tdata layout is unsupported. Export a Telethon session from its source client."
        case .duplicateIdentity: return "This account already exists. Its current session was preserved."
        case .conflictingSessions: return "There are different session keys for the same account. Select one backup for that account and try again."
        case .unavailable: return "The account session runtime is unavailable in this build."
        case .cancelled: return "Account import cancelled."
        case .timeout: return "Telegram did not finish verifying the session in time. Try again when connected."
        case let .storage(status): return "Keychain operation failed (OSStatus \(status)). Unlock the device and try again."
        case .storageVerification: return "The Keychain write could not be verified. Reload the saved sessions before retrying."
        case .authorizationRejected: return "Telegram rejected this session. It may have expired or been revoked."
        case .tokenInvalid: return "Telegram rejected the bot token. Check the token from BotFather."
        case .tokenExpired: return "The bot token has expired or been revoked."
        case .passwordRequired: return "Telegram requires a password. Use the regular account login flow."
        case let .floodWait(seconds): return "Telegram requires a wait of \(seconds) seconds before retrying."
        case .network: return "Telegram could not verify the account. Check the connection and try again."
        }
    }

    public static func authorization(_ description: String) -> WhitegramSessionError {
        if description.hasPrefix("FLOOD_WAIT_"), let seconds = Int32(description.dropFirst(11)), seconds >= 0 {
            return .floodWait(seconds)
        }
        switch description {
        case "ACCESS_TOKEN_INVALID", "BOT_TOKEN_INVALID": return .tokenInvalid
        case "ACCESS_TOKEN_EXPIRED": return .tokenExpired
        case "SESSION_PASSWORD_NEEDED": return .passwordRequired
        case "AUTH_KEY_UNREGISTERED", "AUTH_KEY_INVALID", "AUTH_KEY_DUPLICATED", "SESSION_REVOKED", "SESSION_EXPIRED", "USER_DEACTIVATED", "USER_DEACTIVATED_BAN": return .authorizationRejected
        default: return .network
        }
    }
}

public struct WhitegramSessionIdentity: Hashable {
    public let userId: Int64
    public let testingEnvironment: Bool

    public init(userId: Int64, testingEnvironment: Bool) {
        self.userId = userId
        self.testingEnvironment = testingEnvironment
    }

    public var keychainId: String { return "\(testingEnvironment ? "test" : "production"):\(userId)" }

    // Postbox stores the namespace between the low and high portions of a 61-bit ID.
    public var peerId: Int64 {
        let value = UInt64(bitPattern: userId)
        return Int64(bitPattern: (value & 0xffffffff) | ((value >> 32) << 35))
    }

    public static func fromPeerId(_ peerId: Int64, testingEnvironment: Bool) throws -> WhitegramSessionIdentity {
        let value = UInt64(bitPattern: peerId)
        guard (value >> 32) & 7 == 0 else { throw WhitegramSessionError.missingIdentity }
        let userId = Int64((value & 0xffffffff) | ((value >> 35) << 32))
        guard userId > 0 else { throw WhitegramSessionError.missingIdentity }
        return WhitegramSessionIdentity(userId: userId, testingEnvironment: testingEnvironment)
    }
}

public struct WhitegramPortableAccount: Equatable {
    public let dcId: Int32
    public let authKey: Data
    public let identity: WhitegramSessionIdentity
    public let name: String
    public let phone: String?

    public init(dcId: Int32, authKey: Data, userId: Int64, name: String, phone: String? = nil, testingEnvironment: Bool = false) throws {
        guard (1...5).contains(dcId), !testingEnvironment || dcId <= 3 else { throw WhitegramSessionError.invalidDatacenter }
        guard authKey.count == 256, authKey.contains(where: { $0 != 0 }) else { throw WhitegramSessionError.invalidKey }
        guard userId > 0, userId <= 0x1fffffffffffffff else { throw WhitegramSessionError.missingIdentity }
        guard name.utf8.count <= 4096, (phone?.utf8.count ?? 0) <= 128 else { throw WhitegramSessionError.tooLarge }
        self.dcId = dcId
        self.authKey = authKey
        self.identity = WhitegramSessionIdentity(userId: userId, testingEnvironment: testingEnvironment)
        self.name = name
        self.phone = phone
    }
}

public struct WhitegramSessionBackup: Equatable {
    public struct DatacenterKey: Codable, Equatable {
        public let id: Int32
        public let keyId: Int64
        public let key: Data

        public init(id: Int32, keyId: Int64, key: Data) {
            self.id = id
            self.keyId = keyId
            self.key = key
        }
    }

    public static let maximumBytes = 256 * 1024
    public static let maximumAccounts = 100
    public let account: WhitegramPortableAccount
    public let recordId: Int64
    public let date: Date
    public let additionalDatacenterKeys: [Int32: DatacenterKey]
    public let notificationEncryptionKeyId: Data?
    public let notificationEncryptionKey: Data?

    public init(account: WhitegramPortableAccount, recordId: Int64, date: Date = Date(), additionalDatacenterKeys: [Int32: DatacenterKey] = [:], notificationEncryptionKeyId: Data? = nil, notificationEncryptionKey: Data? = nil) throws {
        guard additionalDatacenterKeys.count <= 10, date.timeIntervalSince1970.isFinite else { throw WhitegramSessionError.invalidFormat }
        for (id, key) in additionalDatacenterKeys {
            guard id == key.id, (1...10).contains(id) else { throw WhitegramSessionError.invalidDatacenter }
            guard key.key.count == 256, key.keyId == WhitegramSessionCrypto.authKeyId(key.key), key.key.contains(where: { $0 != 0 }) else { throw WhitegramSessionError.invalidKey }
            if id == account.dcId, key.key != account.authKey { throw WhitegramSessionError.invalidKey }
        }
        if let notificationEncryptionKeyId, let notificationEncryptionKey {
            guard notificationEncryptionKeyId.count == 8, notificationEncryptionKey.count == 256,
                  notificationEncryptionKeyId == WhitegramSessionCrypto.sha1(notificationEncryptionKey).suffix(8) else { throw WhitegramSessionError.invalidKey }
        } else if notificationEncryptionKeyId != nil || notificationEncryptionKey != nil {
            throw WhitegramSessionError.invalidKey
        }
        self.account = account
        self.recordId = recordId
        self.date = date
        self.additionalDatacenterKeys = additionalDatacenterKeys
        self.notificationEncryptionKeyId = notificationEncryptionKeyId
        self.notificationEncryptionKey = notificationEncryptionKey
    }

    public init(data: Data) throws {
        guard data.count <= Self.maximumBytes else { throw WhitegramSessionError.tooLarge }
        let root: Archive
        do { root = try JSONDecoder().decode(Archive.self, from: data) }
        catch { throw WhitegramSessionError.invalidFormat }
        guard root.accountRecord.attributes.count <= 16 else { throw WhitegramSessionError.invalidFormat }
        let backups = root.accountRecord.attributes.compactMap(\.backupData)
        let environments = root.accountRecord.attributes.compactMap(\.environment)
        guard backups.count == 1, environments.count <= 1,
              let serialized = backups[0].data, serialized.count <= Self.maximumBytes else { throw WhitegramSessionError.invalidFormat }
        let environment = environments.first?.environment ?? 0
        guard environment == 0 || environment == 1 else { throw WhitegramSessionError.invalidFormat }
        let backup: BackupData
        do { backup = try JSONDecoder().decode(BackupData.self, from: serialized) }
        catch { throw WhitegramSessionError.invalidFormat }
        guard backup.masterDatacenterKeyId == WhitegramSessionCrypto.authKeyId(backup.masterDatacenterKey) else { throw WhitegramSessionError.invalidKey }
        let identity = try WhitegramSessionIdentity.fromPeerId(backup.peerId, testingEnvironment: environment == 1)
        let account = try WhitegramPortableAccount(dcId: backup.masterDatacenterId, authKey: backup.masterDatacenterKey, userId: identity.userId, name: root.name ?? "", testingEnvironment: identity.testingEnvironment)
        try self.init(account: account, recordId: root.accountRecord.id, date: root.date, additionalDatacenterKeys: backup.additionalDatacenterKeys ?? [:], notificationEncryptionKeyId: backup.notificationEncryptionKeyId, notificationEncryptionKey: backup.notificationEncryptionKey)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let backup = BackupData(masterDatacenterId: account.dcId, peerId: account.identity.peerId, masterDatacenterKey: account.authKey, masterDatacenterKeyId: WhitegramSessionCrypto.authKeyId(account.authKey), notificationEncryptionKeyId: notificationEncryptionKeyId, notificationEncryptionKey: notificationEncryptionKey, additionalDatacenterKeys: additionalDatacenterKeys)
        let attributes = [Attribute(backupData: BackupAttribute(data: try encoder.encode(backup)), environment: nil), Attribute(backupData: nil, environment: Environment(environment: account.identity.testingEnvironment ? 1 : 0))]
        let data = try encoder.encode(Archive(name: account.name, date: date, accountRecord: Record(id: recordId, attributes: attributes)))
        guard data.count <= Self.maximumBytes else { throw WhitegramSessionError.tooLarge }
        return data
    }

    public static func unique(_ backups: [WhitegramSessionBackup]) throws -> [WhitegramSessionBackup] {
        var identities: [WhitegramSessionIdentity: WhitegramSessionBackup] = [:]
        var result: [WhitegramSessionBackup] = []
        for backup in backups {
            if let previous = identities[backup.account.identity] {
                guard previous.account.dcId == backup.account.dcId, previous.account.authKey == backup.account.authKey else { throw WhitegramSessionError.conflictingSessions }
                continue
            }
            guard result.count < maximumAccounts else { throw WhitegramSessionError.tooLarge }
            identities[backup.account.identity] = backup
            result.append(backup)
        }
        return result
    }

    private struct Archive: Codable {
        let name: String?
        let date: Date
        let accountRecord: Record
    }
    private struct BackupData: Codable {
        let masterDatacenterId: Int32
        let peerId: Int64
        let masterDatacenterKey: Data
        let masterDatacenterKeyId: Int64
        let notificationEncryptionKeyId: Data?
        let notificationEncryptionKey: Data?
        let additionalDatacenterKeys: [Int32: DatacenterKey]?
    }
    private struct BackupAttribute: Codable { let data: Data? }
    private struct Environment: Codable { let environment: Int32 }
    private struct Attribute: Codable {
        let backupData: BackupAttribute?
        let environment: Environment?
    }
    private struct Record: Codable {
        let id: Int64
        let attributes: [Attribute]
        enum CodingKeys: String, CodingKey { case id, attributes }

        init(id: Int64, attributes: [Attribute]) { self.id = id; self.attributes = attributes }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let string = try? container.decode(String.self, forKey: .id), let id = Int64(string) {
                self.id = id
            } else {
                struct LegacyId: Decodable { let rawValue: Int64 }
                self.id = try container.decode(LegacyId.self, forKey: .id).rawValue
            }
            self.attributes = try container.decode([Attribute].self, forKey: .attributes)
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(String(id), forKey: .id)
            try container.encode(attributes, forKey: .attributes)
        }
    }
}

public enum WhitegramAccountSelection {
    public static func next(current: Int64, orderedIds: [Int64], enabled: Bool) -> Int64? {
        guard enabled, orderedIds.count > 1, let index = orderedIds.firstIndex(of: current) else { return nil }
        return orderedIds[(index + 1) % orderedIds.count]
    }

    public static func botUserId(token: String) throws -> Int64 {
        let parts = token.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].utf8.allSatisfy({ (48...57).contains($0) }),
              let userId = Int64(parts[0]), userId > 0, userId <= 0x1fffffffffffffff,
              (16...256).contains(parts[1].utf8.count), parts[1].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw WhitegramSessionError.tokenInvalid }
        return userId
    }
}
