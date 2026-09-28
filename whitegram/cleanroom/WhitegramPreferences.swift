import Foundation
import CoreFoundation

public enum WhitegramPreferences {
    public static let storageKey = "WhitegramSettingsState.v1"
    public static let updatedNotification = Notification.Name("WhitegramSettingsStateUpdated")
    private static let lock = NSRecursiveLock()
    private static var cachedData: Data?
    private static var cachedValues: [String: Any]?

    public static func values() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let defaults = UserDefaults.standard
        let data = defaults.data(forKey: storageKey)
        if let cachedValues, data == cachedData {
            return cachedValues
        }
        var result = dictionary(data)
        if let legacy = defaults.data(forKey: "WhitegramPrivacySettings.v1") {
            for (key, value) in dictionary(legacy) {
                let canonical = key == "saveDeletedMessages" ? "showDeletedMessages" : key
                if result[canonical] == nil { result[canonical] = value }
            }
        }
        cachedData = data
        cachedValues = result
        return result
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
                    if fields[key] is Int && Int(exactly: storedNumber.doubleValue) == nil { continue }
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
