import Foundation
import CoreFoundation

public enum WhitegramPreferences {
    public static let storageKey = "WhitegramSettingsState.v1"
    public static let updatedNotification = Notification.Name("WhitegramSettingsStateUpdated")
    private static let lock = NSRecursiveLock()
    private static var cachedData: Data?
    private static var cachedLegacyData: Data?
    private static var cachedValues: [String: Any]?

    public static func values() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let defaults = UserDefaults.standard
        let data = defaults.data(forKey: storageKey)
        let legacyData = defaults.data(forKey: "WhitegramPrivacySettings.v1")
        if let cachedValues, data == cachedData, legacyData == cachedLegacyData {
            return migrateLocalStarsCount(cachedValues, defaults: defaults)
        }
        var result = dictionary(data)
        if let legacy = defaults.data(forKey: "WhitegramPrivacySettings.v1") {
            for (key, value) in dictionary(legacy) {
                let canonical = key == "saveDeletedMessages" ? "showDeletedMessages" : key
                if result[canonical] == nil { result[canonical] = value }
            }
        }
        cachedData = data
        cachedLegacyData = legacyData
        cachedValues = result
        return migrateLocalStarsCount(result, defaults: defaults)
    }

    private static func dictionary(_ data: Data?) -> [String: Any] {
        guard let data else { return [:] }
        do {
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch {
            NSLog("Whitegram: could not decode saved preferences (%@)", String(describing: type(of: error)))
            return [:]
        }
    }

    public static func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        guard let number = values()[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return defaultValue }
        return number.boolValue
    }

    public static func string(_ key: String, default defaultValue: String = "") -> String {
        return (values()[key] as? String) ?? defaultValue
    }

    public static func number(_ key: String, default defaultValue: Double = 0.0) -> Double {
        guard let number = values()[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return defaultValue }
        return number.doubleValue
    }

    static func exactInteger(_ value: Any) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        if let integer = Int64(number.stringValue) { return integer }
        let decimal = number.decimalValue
        guard decimal >= Decimal(Int64.min), decimal <= Decimal(Int64.max) else { return nil }
        let integer = NSDecimalNumber(decimal: decimal).int64Value
        return Decimal(integer) == decimal ? integer : nil
    }

    private static func migrateLocalStarsCount(_ values: [String: Any], defaults: UserDefaults) -> [String: Any] {
        guard let old = values["localStarsCount"] as? NSNumber, CFGetTypeID(old) == CFBooleanGetTypeID() else { return values }
        var result = values
        let mirrored = defaults.object(forKey: "wg_localStarsCount").flatMap(exactInteger)
        result["localStarsCount"] = mirrored.flatMap { $0 >= 0 ? $0 : nil } ?? Int64(0)
        return result
    }

    private static func strictValues(_ defaults: UserDefaults) throws -> [String: Any] {
        var result: [String: Any] = [:]
        for key in ["WhitegramPrivacySettings.v1", storageKey] {
            guard let object = defaults.object(forKey: key) else { continue }
            guard let data = object as? Data,
                  let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw NSError(domain: "WhitegramPreferences", code: 1, userInfo: [NSLocalizedDescriptionKey: "The saved settings store is invalid. It has not been replaced."])
            }
            for (name, value) in dictionary {
                let name = key == "WhitegramPrivacySettings.v1" && name == "saveDeletedMessages" ? "showDeletedMessages" : name
                result[name] = value
            }
        }
        return migrateLocalStarsCount(result, defaults: defaults)
    }

    static func readForTransfer<T>(_ read: (UserDefaults, [String: Any]) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let defaults = UserDefaults.standard
        return try read(defaults, strictValues(defaults))
    }

    /// Prepares every derived value before committing one canonical JSON snapshot.
    /// Observers run after the lock is released and all derived mirrors are written.
    static func updateForTransfer<T>(_ prepare: (UserDefaults, [String: Any]) throws -> (result: T, changes: [String: Any], mirrors: [String: Any], notifications: [Notification.Name])) throws -> T {
        lock.lock()
        let result: T
        let notifications: [Notification.Name]
        do {
            let defaults = UserDefaults.standard
            var current = try strictValues(defaults)
            let prepared = try prepare(defaults, current)
            for (key, value) in prepared.changes { current[key] = value }
            let data = try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys])
            var mirrors = prepared.mirrors
            for (key, value) in prepared.changes where value is String || value is NSNumber {
                mirrors["wg_" + key] = value
            }
            guard PropertyListSerialization.propertyList(mirrors, isValidFor: .binary) else {
                throw NSError(domain: "WhitegramPreferences", code: 2, userInfo: [NSLocalizedDescriptionKey: "The settings mirrors could not be encoded. Nothing was imported."])
            }
            let changed = data != defaults.data(forKey: storageKey) || mirrors.contains { key, value in
                guard let old = defaults.object(forKey: key) as? NSObject, let value = value as? NSObject else { return true }
                if let old = old as? NSNumber, let value = value as? NSNumber, CFGetTypeID(old) != CFGetTypeID(value) { return true }
                return !old.isEqual(value)
            }
            for (key, value) in mirrors { defaults.set(value, forKey: key) }
            defaults.set(data, forKey: storageKey)
            cachedData = data
            cachedLegacyData = defaults.data(forKey: "WhitegramPrivacySettings.v1")
            cachedValues = current
            result = prepared.result
            notifications = changed ? [updatedNotification] + prepared.notifications : []
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        for name in Set(notifications) { NotificationCenter.default.post(name: name, object: nil) }
        return result
    }

    @discardableResult
    public static func set(_ value: Any, for key: String) -> Bool {
        return update([key: value])
    }

    @discardableResult
    public static func update(_ changes: [String: Any]) -> Bool {
        lock.lock()
        var updated = values()
        for (key, value) in changes {
            updated[key] = value
        }
        guard JSONSerialization.isValidJSONObject(updated) else {
            lock.unlock()
            return false
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys])
            let changed = data != cachedData
            UserDefaults.standard.set(data, forKey: storageKey)
            // These primitives are also read by low-level rendering modules that
            // cannot depend on TelegramCore.
            for (key, value) in changes where value is String || value is NSNumber {
                UserDefaults.standard.set(value, forKey: "wg_" + key)
            }
            cachedData = data
            cachedLegacyData = UserDefaults.standard.data(forKey: "WhitegramPrivacySettings.v1")
            cachedValues = updated
            lock.unlock()
            if changed { NotificationCenter.default.post(name: updatedNotification, object: nil) }
            return true
        } catch {
            lock.unlock()
            NSLog("Whitegram: could not encode preferences (%@)", String(describing: type(of: error)))
            return false
        }
    }

    public static func load<T: Codable>(defaults value: T) -> T {
        do {
            let encoded = try JSONEncoder().encode(value)
            var merged = dictionary(encoded)
            let fields = Dictionary(uniqueKeysWithValues: Mirror(reflecting: value).children.compactMap { child -> (String, Any)? in
                guard let label = child.label else { return nil }
                return (label, child.value)
            })
            for (key, stored) in values() {
                let fallback = merged[key]
                if ["videoBackgroundPath", "profilePhotoWallStatusText", "translationTargetLang"].contains(key) && !(stored is String) { continue }
                if fallback is String && !(stored is String) { continue }
                if fallback is [[String: String]] && !(stored is [[String: String]]) { continue }
                if fallback is [Any] && !(stored is [Any]) { continue }
                if let number = fallback as? NSNumber {
                    guard let storedNumber = stored as? NSNumber else { continue }
                    if (CFGetTypeID(number) == CFBooleanGetTypeID()) != (CFGetTypeID(storedNumber) == CFBooleanGetTypeID()) { continue }
                    if fields[key] is Int || fields[key] is Int64 {
                        guard let integer = exactInteger(storedNumber) else { continue }
                        if fields[key] is Int && Int(exactly: integer) == nil { continue }
                        merged[key] = integer
                        continue
                    }
                }
                merged[key] = stored
            }
            return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: merged))
        } catch {
            NSLog("Whitegram: could not migrate preference snapshot (%@)", String(describing: type(of: error)))
            return value
        }
    }

    @discardableResult
    public static func save<T: Encodable>(_ value: T) -> Bool {
        do {
            return update(dictionary(try JSONEncoder().encode(value)))
        } catch {
            NSLog("Whitegram: invalid preference value (%@)", String(describing: type(of: error)))
            return false
        }
    }
}
