import Foundation

public enum WhitegramSettingsArchiveError: Error, LocalizedError {
    case tooLarge, invalidJSON, duplicateKey, unsupportedFormat, unsupportedVersion
    case unsupportedSetting, invalidValue(String), conflictingSettings, noSettings, invalidPublicStore

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "The settings archive exceeds the size, nesting or item limits."
        case .invalidJSON: return "The settings archive is not valid JSON."
        case .duplicateKey: return "The archive contains duplicate or conflicting aliases for a setting."
        case .unsupportedFormat: return "Use a Whitegram port settings archive. Original IPA backups and arbitrary preference dumps are not supported."
        case .unsupportedVersion: return "This settings archive version is not supported."
        case .unsupportedSetting: return "The archive includes an unknown or non-portable setting. Nothing was imported."
        case let .invalidValue(key): return "The value for \(key) has an invalid type or is outside the supported limits."
        case .conflictingSettings: return "The double-tap action and edit switch conflict. Nothing was imported."
        case .noSettings: return "The archive contains no portable settings."
        case .invalidPublicStore: return "An existing public-fork settings store is invalid. Nothing was imported."
        }
    }
}

public struct WhitegramSettingsArchive {
    public static let format = "whitegram.settings.port"
    public static let version: Int64 = 1
    public static let maximumBytes = 128 * 1024
    public let createdAt: Int64
    public let migratedKeys: [String]
    let values: [String: Any]

    public var keys: [String] { return values.keys.sorted() }
    public var privacyKeys: [String] {
        return keys.filter { $0 == "ghostModeEnabled" || $0.hasPrefix("disable") || ["alwaysOnline", "readOnAction", "whitegramPresenceEnabled", "whitegramPresencePreciseEnabled", "saveChatHistory", "showDeletedMessages", "showEditedOriginalText"].contains($0) }
    }

    public init(data: Data) throws {
        do {
            var checker = try WhitegramSettingsArchiveJSON(data)
            try checker.check()
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(root.keys) == ["format", "version", "createdAt", "settings"],
                  root["format"] as? String == Self.format else { throw WhitegramSettingsArchiveError.unsupportedFormat }
            guard let version = root["version"].flatMap(WhitegramPreferences.exactInteger), version == Self.version else { throw WhitegramSettingsArchiveError.unsupportedVersion }
            guard let date = root["createdAt"].flatMap(WhitegramPreferences.exactInteger), (0...253402300799).contains(date),
                  let settings = root["settings"] as? [String: Any] else { throw WhitegramSettingsArchiveError.invalidJSON }
            let normalized = try WhitegramSettingsArchiveSchema.validate(settings)
            guard !normalized.values.isEmpty else { throw WhitegramSettingsArchiveError.noSettings }
            self.createdAt = date
            self.values = normalized.values
            self.migratedKeys = normalized.migrated
        } catch let error as WhitegramSettingsArchiveError {
            throw error
        } catch {
            throw WhitegramSettingsArchiveError.invalidJSON
        }
    }

    public func encoded() throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: ["format": Self.format, "version": Self.version, "createdAt": createdAt, "settings": values], options: [.sortedKeys, .prettyPrinted])
        guard data.count <= Self.maximumBytes else { throw WhitegramSettingsArchiveError.tooLarge }
        return data
    }

    static func export(values: [String: Any], date: Date) throws -> WhitegramSettingsArchiveExport {
        var settings: [String: Any] = [:]
        var skipped: [String] = []
        for key in WhitegramSettingsArchiveSchema.rules.keys.sorted() {
            guard let value = values[key], let rule = WhitegramSettingsArchiveSchema.rules[key] else { continue }
            do { settings[key] = try rule.validate(value, key: key) }
            catch { skipped.append(key) }
        }
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite, timestamp >= 0, timestamp <= 253402300799 else { throw WhitegramSettingsArchiveError.invalidJSON }
        let data = try JSONSerialization.data(withJSONObject: ["format": format, "version": version, "createdAt": Int64(timestamp), "settings": settings])
        let archive = try WhitegramSettingsArchive(data: data)
        return WhitegramSettingsArchiveExport(archive: archive, omittedInvalidKeys: skipped)
    }
}

public struct WhitegramSettingsArchiveExport {
    public let archive: WhitegramSettingsArchive
    public let omittedInvalidKeys: [String]
}

public struct WhitegramSettingsArchiveImportResult {
    public let importedKeys: [String]
    public let restartRecommended: Bool
}
