import Foundation
import CoreFoundation

public struct WhitegramTranslationSettings: Equatable {
    public static let targetKey = "translationTargetLang"
    public static let beforeSendingKey = "translateBeforeSending"
    public static let localKey = "localTranslationEnabled"
    public static let voiceKey = "voiceTranslationEnabled"
    public static let siriWarningKey = "showSiriTranscriptionWarning"
    public static let siriDismissedKey = "siriTranscriptionWarningDismissed"
    public static let appleKey = "translationUseApple"
    public static let reviewBeforeSendingKey = "translationReviewBeforeSending"
    public static let transcriptsKey = "translationTranslateTranscripts"

    public static let originalKeys: [String: String] = [
        targetKey: "wg_translationTargetLang",
        beforeSendingKey: "wg_translateBeforeSending",
        localKey: "wg_localTranslationEnabled",
        voiceKey: "wg_voiceTranslationEnabled",
        siriWarningKey: "wg_showSiriTranscriptionWarning",
        siriDismissedKey: "wg_siriTranscriptionWarningDismissed"
    ]

    private static let mirrorKeys = WhitegramTranslationSettings.originalKeys.merging([
        appleKey: "wg_translationUseApple",
        reviewBeforeSendingKey: "wg_translationReviewBeforeSending",
        transcriptsKey: "wg_translationTranslateTranscripts"
    ], uniquingKeysWith: { _, new in new })

    public let targetLanguage: String
    public let beforeSending: Bool
    public let localTranslationRequested: Bool
    public let voiceTranslationRequested: Bool
    public let siriWarningRequested: Bool
    public let siriWarningDismissed: Bool
    public let appleTranslationRequested: Bool
    public let reviewBeforeSending: Bool
    public let translateTranscripts: Bool

    public init(values: [String: Any], originalValues: [String: Any] = [:]) {
        func value(_ key: String) -> Any? {
            if let value = values[key] { return value }
            return Self.mirrorKeys[key].flatMap { originalValues[$0] }
        }
        func boolean(_ key: String, default fallback: Bool = false) -> Bool {
            guard let number = value(key) as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return fallback }
            return number.boolValue
        }
        self.targetLanguage = (value(Self.targetKey) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.beforeSending = boolean(Self.beforeSendingKey)
        self.localTranslationRequested = boolean(Self.localKey)
        self.voiceTranslationRequested = boolean(Self.voiceKey)
        // The original getter returns true unconditionally; dismissal is a different key.
        self.siriWarningRequested = true
        self.siriWarningDismissed = boolean(Self.siriDismissedKey)
        self.appleTranslationRequested = boolean(Self.appleKey)
        self.reviewBeforeSending = boolean(Self.reviewBeforeSendingKey)
        self.translateTranscripts = boolean(Self.transcriptsKey, default: true)
    }

    public static var current: WhitegramTranslationSettings {
        var originalValues: [String: Any] = [:]
        for key in Self.mirrorKeys.values {
            originalValues[key] = UserDefaults.standard.object(forKey: key)
        }
        return WhitegramTranslationSettings(values: WhitegramPreferences.values(), originalValues: originalValues)
    }

    /// Empty means Telegram's normal per-chat/UI-language choice, not English.
    public var hasGlobalTarget: Bool { return !self.targetLanguage.isEmpty }

    public var showsSendAction: Bool { return self.localTranslationRequested && self.beforeSending && !self.appleTranslationRequested }

    public func transcriptionEnabled(nativeEnabled: Bool) -> Bool {
        return self.voiceTranslationRequested || nativeEnabled
    }

    public func usesAppleTranscription(nativeEnabled: Bool, appleSelected: Bool) -> Bool {
        return self.voiceTranslationRequested || (nativeEnabled && appleSelected)
    }

    public var shouldShowSiriWarning: Bool { return self.siriWarningRequested && !self.siriWarningDismissed }

    /// Call on the main queue immediately before presenting the original informational notice.
    public static func claimSiriWarning() -> Bool {
        precondition(Thread.isMainThread)
        guard Self.current.shouldShowSiriWarning else { return false }
        return WhitegramPreferences.set(true, for: Self.siriDismissedKey)
    }

    public func resolvedTarget(baseLanguage: String, supportedLanguages: [String]) -> String? {
        return Self.supportedCode(self.hasGlobalTarget ? self.targetLanguage : baseLanguage, in: supportedLanguages)
    }

    /// Original With Translation action: device language, or English/Russian when the draft is already in it.
    public func resolvedOutgoingTarget(detectedLanguage: String?, preferredLanguages: [String], supportedLanguages: [String]) -> String? {
        if self.hasGlobalTarget { return Self.supportedCode(self.targetLanguage, in: supportedLanguages) }
        guard let preferred = Self.supportedCode(preferredLanguages.first ?? "en", in: supportedLanguages) else { return nil }
        let detected = detectedLanguage.flatMap { Self.supportedCode($0, in: supportedLanguages) } ?? preferred
        return detected == preferred ? Self.supportedCode(preferred == "en" ? "ru" : "en", in: supportedLanguages) : preferred
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
