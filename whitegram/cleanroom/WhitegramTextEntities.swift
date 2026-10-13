import Foundation
import Postbox

public enum WhitegramTextEntities {
    public static func outgoing(text: String, entities: [MessageTextEntity], enabled: Bool = true) -> (text: String, entities: [MessageTextEntity]) {
        guard enabled else { return (text, entities) }
        let settings = WhitegramTextSettings.current
        var entities = entities
        let type: MessageTextEntityType?
        switch settings.style {
        case .off: type = nil
        case .bold: type = .Bold
        case .italic: type = .Italic
        case .monospace: type = .Code
        case .strikethrough: type = .Strikethrough
        case .spoiler: type = .Spoiler
        }
        if let type, !text.isEmpty {
            let excluded = entities.compactMap { entity -> Range<Int>? in
                if settings.style == .monospace { return entity.range }
                switch entity.type {
                case .Code, .Pre: return entity.range
                default: return entity.type == type ? entity.range : nil
                }
            }
            for range in WhitegramTextSettings.formattingRanges(in: text, excluding: excluded) {
                entities.append(MessageTextEntity(range: range, type: type))
            }
        }
        let preserved = entities.compactMap { entity -> Range<Int>? in
            switch entity.type {
            case .Url, .Email, .Mention, .TextMention, .Hashtag, .BotCommand, .PhoneNumber, .BankCard, .CustomEmoji, .FormattedDate, .Code, .Pre:
                return entity.range
            default: return nil
            }
        }
        return (settings.outgoingText(text, preserving: preserved), entities)
    }

    public static func display(text: String, entities: [MessageTextEntity]?) -> (text: String, entities: [MessageTextEntity]?) {
        guard WhitegramTextSettings.current.zalgoFilter else { return (text, entities) }
        let filtered = WhitegramFilteredText(text)
        return (filtered.text, entities?.compactMap { entity in
            guard let range = filtered.mapRange(entity.range) else { return nil }
            return MessageTextEntity(range: range, type: entity.type)
        })
    }
}
