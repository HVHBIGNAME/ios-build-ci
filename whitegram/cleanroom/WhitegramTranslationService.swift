import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import AccountContext

public enum WhitegramTranslationFailure: Error {
    case network(TranslationError)
    case invalidTarget
    case sourceTooLong
    case emptyResult
    case invalidEntities
    case unsupportedContent
    case localUnavailable
    case voiceDisabled
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
        case .unsupportedContent:
            return "Before-send translation supports text and basic formatting. Rich blocks, custom emoji and formatted dates must be sent as originally composed."
        case .localUnavailable:
            return "Apple translation requires iOS 18 and a supported language pair. Allow the system language download when prompted, or explicitly choose a network provider. Your original text has been kept."
        case .voiceDisabled:
            return "Enable Translate Completed Transcripts in Whitegram → Translation."
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

func whitegramTranslationSupports(_ entity: MessageTextEntity) -> Bool {
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
public func whitegramTranslateDraft(context: AccountContext, text: String, entities: [MessageTextEntity], toLang: String, provider: WhiteGramOtherTranslationService, fromLang: String? = nil) -> Signal<WhitegramTranslationResult, WhitegramTranslationFailure> {
    guard supportedTranslationLanguages.contains(toLang) else { return .fail(.invalidTarget) }
    guard WhitegramTranslationTextRules.hasText(text) else { return .fail(.emptyResult) }
    guard text.utf16.count <= WhitegramTranslationTextRules.maximumSourceUTF16Length else { return .fail(.sourceTooLong) }
    guard entities.allSatisfy({ WhitegramTranslationTextRules.validRange($0.range, in: text) }) else { return .fail(.invalidEntities) }
    guard entities.allSatisfy(whitegramTranslationSupports) else { return .fail(.unsupportedContent) }

    let request: Signal<(String, [MessageTextEntity])?, TranslationError>
    if WhitegramTranslationSettings.current.appleTranslationRequested {
        return whitegramTranslateWithSegments(text: text, entities: entities, translate: { texts in
            return whitegramAppleTranslate(context: context, texts: texts, fromLang: fromLang, toLang: toLang)
        })
        |> timeout(120.0, queue: .mainQueue(), alternate: .fail(.timedOut))
    }
    switch provider {
    case .telegram:
        request = context.engine.messages.translate(text: text, toLang: toLang, entities: entities)
    case .gTranslate:
        return whitegramTranslateWithSegments(text: text, entities: entities, translate: { texts in
            // A highly formatted draft must not fan out hundreds of simultaneous HTTP requests.
            return texts.reduce(Signal<[String], WhitegramTranslationFailure>.single([])) { previous, source in
                previous |> mapToSignal { completed in
                    whitegramTranslateGoogleText(text: source, fromLang: fromLang, toLang: toLang)
                    |> map { completed + [$0] }
                }
            }
        })
        |> timeout(30.0, queue: .mainQueue(), alternate: .fail(.timedOut))
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

func whitegramTranslateGoogleText(text: String, fromLang: String?, toLang: String) -> Signal<String, WhitegramTranslationFailure> {
    return Signal { subscriber in
        let task = WhitegramTranslationGoogle.translate(text: text, fromLang: fromLang, toLang: toLang) { result in
            switch result {
            case let .success(text): subscriber.putNext(text); subscriber.putCompletion()
            case .failure(.timedOut): subscriber.putError(.timedOut)
            case .failure(.httpStatus(429)): subscriber.putError(.network(.limitExceeded))
            case .failure(.invalidResponse), .failure(.responseTooLarge): subscriber.putError(.emptyResult)
            case .failure: subscriber.putError(.network(.generic))
            }
        }
        return ActionDisposable { task.cancel() }
    }
}

private func whitegramTranslateWithSegments(text: String, entities: [MessageTextEntity], translate: @escaping ([String]) -> Signal<[String], WhitegramTranslationFailure>) -> Signal<WhitegramTranslationResult, WhitegramTranslationFailure> {
    let protectedRanges = entities.filter { whitegramTranslationProtectedText($0, text: text) != nil }.map { $0.range }
    guard let segments = WhitegramTranslationSegments(text: text, entityRanges: entities.map { $0.range }, protectedRanges: protectedRanges) else { return .fail(.invalidEntities) }
    let result: Signal<[String], WhitegramTranslationFailure> = segments.requests.isEmpty ? .single([]) : translate(segments.requests)
    return result |> mapToSignal { translated -> Signal<WhitegramTranslationResult, WhitegramTranslationFailure> in
        guard let assembled = segments.assemble(translated, entityRanges: entities.map { $0.range }) else { return .fail(.invalidEntities) }
        let resultEntities = zip(entities, assembled.ranges).map { MessageTextEntity(range: $0.1, type: $0.0.type) }
        guard whitegramTranslationPreservesEntities(source: text, sourceEntities: entities, result: assembled.text, resultEntities: resultEntities) else { return .fail(.invalidEntities) }
        return .single(WhitegramTranslationResult(text: assembled.text, entities: resultEntities))
    }
}

/// Audio integration: translates an already-final transcript, never records/transcribes audio or changes its source attribute.
public func whitegramTranslateVoiceText(context: AccountContext, text: String, toLang: String? = nil) -> Signal<WhitegramTranslationResult, WhitegramTranslationFailure> {
    let settings = WhitegramTranslationSettings.current
    guard settings.translateTranscripts else { return .fail(.voiceDisabled) }
    guard let target = toLang ?? settings.resolvedTarget(baseLanguage: context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode, supportedLanguages: supportedTranslationLanguages) else { return .fail(.invalidTarget) }
    let provider: WhiteGramOtherTranslationService = settings.localTranslationRequested ? .gTranslate : WhiteGramOtherSettings.current.translationService
    return whitegramTranslateDraft(context: context, text: text, entities: [], toLang: target, provider: provider)
}

func whitegramTranslateReceivedMessages(context: AccountContext, messageIds: [EngineMessage.Id], toLang: String, provider: WhiteGramOtherTranslationService) -> Signal<Never, TranslationError> {
    return whitegramTranslateMessageBatch(account: context.account, messageIds: messageIds, toLang: toLang, translate: { text, entities in
        return whitegramTranslateDraft(context: context, text: text, entities: entities, toLang: toLang, provider: provider)
        |> map { ($0.text, $0.entities) }
        |> mapError { _ in TranslationError.generic }
    })
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
