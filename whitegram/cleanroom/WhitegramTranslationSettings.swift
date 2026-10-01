import Foundation
import CoreFoundation

public struct WhitegramTranslationSettings: Equatable {
    public static let targetKey = "translationTargetLang"
    public static let beforeSendingKey = "translateBeforeSending"
    public static let localKey = "localTranslationEnabled"
    public static let voiceKey = "voiceTranslationEnabled"
    public static let siriWarningKey = "showSiriTranscriptionWarning"

    public static let originalKeys: [String: String] = [
        targetKey: "wg_translationTargetLang",
        beforeSendingKey: "wg_translateBeforeSending",
        localKey: "wg_localTranslationEnabled",
        voiceKey: "wg_voiceTranslationEnabled",
        siriWarningKey: "wg_showSiriTranscriptionWarning"
    ]

    public let targetLanguage: String
    public let beforeSending: Bool
    public let localTranslationRequested: Bool
    public let voiceTranslationRequested: Bool
    public let siriWarningRequested: Bool

    public init(values: [String: Any], originalValues: [String: Any] = [:]) {
        func value(_ key: String) -> Any? {
            if let value = values[key] { return value }
            return Self.originalKeys[key].flatMap { originalValues[$0] }
        }
        func boolean(_ key: String) -> Bool {
            guard let number = value(key) as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return number.boolValue
        }
        self.targetLanguage = (value(Self.targetKey) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.beforeSending = boolean(Self.beforeSendingKey)
        self.localTranslationRequested = boolean(Self.localKey)
        self.voiceTranslationRequested = boolean(Self.voiceKey)
        self.siriWarningRequested = boolean(Self.siriWarningKey)
    }

    public static var current: WhitegramTranslationSettings {
        var originalValues: [String: Any] = [:]
        for key in Self.originalKeys.values {
            originalValues[key] = UserDefaults.standard.object(forKey: key)
        }
        return WhitegramTranslationSettings(values: WhitegramPreferences.values(), originalValues: originalValues)
    }

    /// Empty means Telegram's normal per-chat/UI-language choice, not English.
    public var hasGlobalTarget: Bool { return !self.targetLanguage.isEmpty }

    public func resolvedTarget(baseLanguage: String, supportedLanguages: [String]) -> String? {
        return Self.supportedCode(self.hasGlobalTarget ? self.targetLanguage : baseLanguage, in: supportedLanguages)
    }

    public static func supportedCode(_ language: String, in supportedLanguages: [String]) -> String? {
        var code = language.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-")
        if code.hasSuffix("-raw") { code = String(code.dropLast(4)) }
        if let exact = supportedLanguages.first(where: { $0.lowercased() == code.lowercased() }) { return exact }
        var base = code.components(separatedBy: "-")[0].lowercased()
        if base == "nb" { base = "no" }
        return supportedLanguages.first(where: { $0.lowercased() == base })
    }
}
