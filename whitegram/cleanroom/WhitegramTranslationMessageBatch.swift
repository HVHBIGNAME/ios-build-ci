import Foundation
import Postbox
import SwiftSignalKit

/// Stores only successful, still-current translations and keeps the original message/transcript intact.
public func whitegramTranslateMessageBatch(account: Account, messageIds: [EngineMessage.Id], toLang: String, translate: @escaping (String, [MessageTextEntity]) -> Signal<(String, [MessageTextEntity]), TranslationError>) -> Signal<Never, TranslationError> {
    let settings = WhitegramTranslationSettings.current
    return account.postbox.transaction { transaction -> [Message] in
        messageIds.compactMap { transaction.getMessage($0) }
    }
    |> castError(TranslationError.self)
    |> mapToSignal { messages -> Signal<Never, TranslationError> in
        let signals: [Signal<(Message, TranslationMessageAttribute?), TranslationError>] = messages.map { message in
            let translated: Signal<TranslationMessageAttribute?, TranslationError>
            if message.attributes.contains(where: { $0 is RichTextMessageAttribute }) {
                // Apple/Google's text APIs have no rich-message structure contract.
                translated = .fail(.generic)
            } else if let poll = message.media.first as? TelegramMediaPoll {
                var texts: [(String, [MessageTextEntity])] = [(poll.text, poll.textEntities)]
                texts += poll.options.map { ($0.text, $0.entities) }
                if let solution = poll.results.solution { texts.append((solution.text, solution.entities)) }
                translated = combineLatest(texts.map { translate($0.0, $0.1) })
                |> map { values -> TranslationMessageAttribute? in
                    guard values.count == texts.count, let title = values.first else { return nil }
                    let options = values.dropFirst().prefix(poll.options.count).map { TranslationMessageAttribute.Additional(text: $0.0, entities: $0.1) }
                    let solution = poll.results.solution == nil ? nil : values.last.map { TranslationMessageAttribute.Additional(text: $0.0, entities: $0.1) }
                    return TranslationMessageAttribute(text: title.0, entities: title.1, additional: options, pollSolution: solution, toLang: toLang)
                }
            } else {
                var text = message.text
                var entities = message.textEntitiesAttribute?.entities ?? []
                if text.isEmpty, settings.translateTranscripts,
                   let transcript = message.attributes.first(where: { $0 is AudioTranscriptionMessageAttribute }) as? AudioTranscriptionMessageAttribute,
                   !transcript.isPending, transcript.error == nil {
                    text = transcript.text
                    entities = []
                }
                if WhitegramTranslationTextRules.hasText(text) {
                    translated = translate(text, entities)
                    |> map { TranslationMessageAttribute(text: $0.0, entities: $0.1, toLang: toLang) }
                } else {
                    translated = .single(nil)
                }
            }
            return translated |> map { (message, $0) }
        }
        guard !signals.isEmpty else { return .complete() }
        return combineLatest(signals)
        |> mapToSignal { results -> Signal<Never, TranslationError> in
            return account.postbox.transaction { transaction in
                guard WhitegramTranslationSettings.current == settings else { return }
                for (source, attribute) in results {
                    guard let attribute else { continue }
                    transaction.updateMessage(source.id, update: { current in
                        guard current.stableVersion == source.stableVersion else { return .skip }
                        var attributes = current.attributes.filter { !($0 is TranslationMessageAttribute) }
                        attributes.append(attribute)
                        return .update(StoreMessage(id: current.id, customStableId: nil, globallyUniqueId: current.globallyUniqueId, groupingKey: current.groupingKey, threadId: current.threadId, timestamp: current.timestamp, flags: StoreMessageFlags(current.flags), tags: current.tags, globalTags: current.globalTags, localTags: current.localTags, forwardInfo: current.forwardInfo.flatMap(StoreMessageForwardInfo.init), authorId: current.author?.id, text: current.text, attributes: attributes, media: current.media))
                    })
                }
            }
            |> castError(TranslationError.self)
            |> ignoreValues
        }
    }
}
