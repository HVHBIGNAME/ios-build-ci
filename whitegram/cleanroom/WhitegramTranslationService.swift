import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import AccountContext

public enum WhitegramTranslationFailure {
    case network(TranslationError)
    case invalidTarget
    case sourceTooLong
    case emptyResult
    case invalidEntities
    case googleFormatting
    case unsupportedContent
    case localUnavailable
    case timedOut

    public var message: String {
        switch self {
        case .invalidTarget:
            return "Choose a supported target language in Whitegram → Translation."
        case .sourceTooLong:
            return "Before-send translation supports up to 4096 UTF-16 characters at a time. Shorten this draft or send the original."
        case .emptyResult:
            return "The translation service returned no usable text. Your draft has been kept."
        case .invalidEntities:
            return "The translation could not preserve the draft's formatting, links or mentions. Your original draft has been kept."
        case .googleFormatting:
            return "Google's native integration returns plain text only. Choose Telegram in Translation settings for drafts with formatting, links or mentions."
        case .unsupportedContent:
            return "Before-send translation supports text and basic formatting. Rich blocks, custom emoji and formatted dates must be sent as originally composed."
        case .localUnavailable:
            return "The saved on-device translation request is unavailable in this port. Select a network provider in Translation settings to use before-send translation."
        case .timedOut:
            return "Translation timed out. Check your connection and try again. Your draft has been kept."
        case let .network(error):
            switch error {
            case .limitExceeded: return "The translation service is rate-limited. Please try again later."
            case .invalidLanguage: return "The service does not support this target language. Choose another language."
            case .textTooLong: return "The translation service rejected this draft's length. Shorten it or send the original."
            case .textIsEmpty: return "The translation service could not read this draft."
            case .tryAlternative: return "Telegram translation is unavailable. You can explicitly select Google in Translation settings for plain-text drafts."
            case .generic, .invalidMessageId: return "Translation failed. Check your connection and try again. Your draft has been kept."
            }
        }
    }
}

public struct WhitegramTranslationResult {
    public let text: String
    public let entities: [MessageTextEntity]
}

private func whitegramTranslationSupports(_ entity: MessageTextEntity) -> Bool {
    switch entity.type {
    case .Unknown, .Custom, .CustomEmoji, .FormattedDate, .BankCard:
        return false
    default:
        return true
    }
}

private func whitegramTranslationProtectedText(_ entity: MessageTextEntity, text: String) -> String? {
    switch entity.type {
    case .Mention, .Hashtag, .BotCommand, .Url, .Email, .PhoneNumber, .Code, .Pre:
        return (text as NSString).substring(with: NSRange(location: entity.range.lowerBound, length: entity.range.count))
    default:
        return nil
    }
}

/// Offsets belong to each version of the text. Only entity kinds/payloads are matched across versions.
public func whitegramTranslationPreservesEntities(source: String, sourceEntities: [MessageTextEntity], result: String, resultEntities: [MessageTextEntity]) -> Bool {
    guard sourceEntities.count == resultEntities.count,
          sourceEntities.allSatisfy({ whitegramTranslationSupports($0) && WhitegramTranslationTextRules.validRange($0.range, in: source) }),
          resultEntities.allSatisfy({ whitegramTranslationSupports($0) && WhitegramTranslationTextRules.validRange($0.range, in: result) }) else { return false }
    var remaining = resultEntities
    for entity in sourceEntities {
        let protectedText = whitegramTranslationProtectedText(entity, text: source)
        guard let index = remaining.firstIndex(where: {
            $0.type == entity.type && whitegramTranslationProtectedText($0, text: result) == protectedText
        }) else { return false }
        remaining.remove(at: index)
    }
    return remaining.isEmpty
}

/// Uses the existing providers without a silent switch of service or guessed formatting offsets.
public func whitegramTranslateDraft(context: AccountContext, text: String, entities: [MessageTextEntity], toLang: String, provider: WhiteGramOtherTranslationService) -> Signal<WhitegramTranslationResult, WhitegramTranslationFailure> {
    guard supportedTranslationLanguages.contains(toLang) else { return .fail(.invalidTarget) }
    guard WhitegramTranslationTextRules.hasText(text) else { return .fail(.emptyResult) }
    guard text.utf16.count <= WhitegramTranslationTextRules.maximumSourceUTF16Length else { return .fail(.sourceTooLong) }
    guard entities.allSatisfy({ WhitegramTranslationTextRules.validRange($0.range, in: text) }) else { return .fail(.invalidEntities) }
    guard entities.allSatisfy(whitegramTranslationSupports) else { return .fail(.unsupportedContent) }

    let request: Signal<(String, [MessageTextEntity])?, TranslationError>
    switch provider {
    case .telegram:
        request = context.engine.messages.translate(text: text, toLang: toLang, entities: entities)
    case .gTranslate:
        guard entities.isEmpty else { return .fail(.googleFormatting) }
        request = alternativeTranslateText(text: text, fromLang: nil, toLang: toLang)
    }
    return request
    |> mapError { WhitegramTranslationFailure.network($0) }
    |> mapToSignal { result -> Signal<WhitegramTranslationResult, WhitegramTranslationFailure> in
        guard let (translated, translatedEntities) = result,
              WhitegramTranslationTextRules.hasText(translated),
              translated.utf16.count <= WhitegramTranslationTextRules.maximumResultUTF16Length else { return .fail(.emptyResult) }
        guard whitegramTranslationPreservesEntities(source: text, sourceEntities: entities, result: translated, resultEntities: translatedEntities) else { return .fail(.invalidEntities) }
        return .single(WhitegramTranslationResult(text: translated, entities: translatedEntities))
    }
    |> take(1)
    |> timeout(30.0, queue: .mainQueue(), alternate: .fail(.timedOut))
}

/// A configured global target overrides the default; an empty/invalid one preserves native selection.
public func whitegramTranslationTarget(defaultLanguage: String) -> String {
    let settings = WhitegramTranslationSettings.current
    guard settings.hasGlobalTarget else { return defaultLanguage }
    return settings.resolvedTarget(baseLanguage: defaultLanguage, supportedLanguages: supportedTranslationLanguages) ?? defaultLanguage
}

/// Restart native translation-state observation when its global inputs change.
public func whitegramTranslationSettingsSignal() -> Signal<WhitegramTranslationSettings, NoError> {
    return Signal { subscriber in
        let emit = { subscriber.putNext(WhitegramTranslationSettings.current) }
        let observer = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main) { _ in emit() }
        emit()
        return ActionDisposable { NotificationCenter.default.removeObserver(observer) }
    }
}
