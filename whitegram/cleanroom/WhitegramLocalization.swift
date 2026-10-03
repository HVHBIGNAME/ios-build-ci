import Foundation

public enum WhitegramLocalization {
    public static let builtInLanguages = ["ru", "uk", "en"]

    public static func normalizedLanguage(_ code: String) -> String {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
        if value == "ru" || value.hasPrefix("ru-") { return "ru" }
        if value == "uk" || value.hasPrefix("uk-") { return "uk" }
        return "en"
    }

    public static func selectedLanguage(baseLanguage: String = "") -> String {
        let values = WhitegramPreferences.values()
        if let selected = (values["menuLanguageCode"] ?? UserDefaults.standard.object(forKey: "wg_menuLanguageCode")) as? String,
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalizedLanguage(selected)
        }
        let fallback = baseLanguage.isEmpty ? (UserDefaults.standard.string(forKey: "wg_tgBaseLanguageCode") ?? "en") : baseLanguage
        return normalizedLanguage(fallback)
    }

    public static func rememberBaseLanguage(_ code: String) {
        guard !code.isEmpty, UserDefaults.standard.string(forKey: "wg_tgBaseLanguageCode") != code else { return }
        UserDefaults.standard.set(code, forKey: "wg_tgBaseLanguageCode")
    }

    @discardableResult
    public static func setLanguage(_ code: String) -> Bool {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let index = builtInLanguages.firstIndex(of: code) else { return false }
        let saved = WhitegramPreferences.update(["menuLanguageCode": code, "menuLanguage": index])
        if saved { NotificationCenter.default.post(name: WhitegramLocalizationStore.changedNotification, object: nil) }
        return saved
    }

    public static func builtInString(_ key: String, language: String) -> String? {
        guard let translations = WhitegramLocalizationStrings.values[key] else { return nil }
        let index = builtInLanguages.firstIndex(of: normalizedLanguage(language)) ?? 2
        return translations[index]
    }

    public static func string(_ key: String, baseLanguage: String = "", fallback: String? = nil, store: WhitegramLocalizationStore = .shared) -> String {
        if let pack = try? store.activePack(), let value = pack.entries[key] { return value }
        return builtInString(key, language: selectedLanguage(baseLanguage: baseLanguage)) ?? fallback ?? key
    }

    public static func format(_ key: String, _ arguments: [String], baseLanguage: String = "", store: WhitegramLocalizationStore = .shared) -> String {
        let template = string(key, baseLanguage: baseLanguage, store: store)
        var result = ""
        var cursor = template.startIndex
        while let range = template.range(of: "%[1-9][0-9]*", options: .regularExpression, range: cursor..<template.endIndex) {
            result += template[cursor..<range.lowerBound]
            if let number = Int(template[range].dropFirst()), number <= arguments.count {
                result += arguments[number - 1]
            } else {
                result += template[range]
            }
            cursor = range.upperBound
        }
        result += template[cursor...]
        return result
    }

    public static func exportPack(baseLanguage: String, store: WhitegramLocalizationStore = .shared) throws -> WhitegramLocalizationPack {
        let language = selectedLanguage(baseLanguage: baseLanguage)
        let custom = try store.activePack()
        let entries = Dictionary(uniqueKeysWithValues: WhitegramLocalizationStrings.values.keys.map {
            ($0, custom?.entries[$0] ?? builtInString($0, language: language) ?? $0)
        })
        return WhitegramLocalizationPack(name: custom?.name ?? "Whitegram", author: custom?.author ?? "", languageCode: custom?.languageCode ?? language, entries: entries)
    }
}
