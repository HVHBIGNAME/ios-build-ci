import Foundation
import Postbox

public final class WhitegramHistoryEdit: PostboxCoding {
    public let text: String
    public let entities: [MessageTextEntity]
    public let date: Int32

    public init(text: String, entities: [MessageTextEntity], date: Int32) {
        self.text = text
        self.entities = entities
        self.date = date
    }

    public init(decoder: PostboxDecoder) {
        self.text = decoder.decodeStringForKey("t", orElse: "")
        self.entities = decoder.decodeObjectArrayWithDecoderForKey("e")
        self.date = decoder.decodeInt32ForKey("d", orElse: 0)
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeString(self.text, forKey: "t")
        encoder.encodeObjectArray(self.entities, forKey: "e")
        encoder.encodeInt32(self.date, forKey: "d")
    }
}

/// Persisted with the real message, not with the bounded observation archive.
/// The original SGMessageAttribute also stores deletion state, original entities,
/// and text/date edit history. Media stays on the real Postbox message.
public final class WhitegramHistoryMessageAttribute: WhitegramHistoryPersistentAttribute {
    public let isDeleted: Bool
    public let deletedAt: Int32?
    public let isLocallyRestored: Bool
    public let isShortened: Bool
    public let edits: [WhitegramHistoryEdit]

    public var originalText: String? { return self.edits.first?.text }
    public var originalEntities: [MessageTextEntity]? { return self.edits.first?.entities }
    public var whitegramPreserveGlobalDeletion: Bool { return self.isDeleted }

    public init(isDeleted: Bool = false, deletedAt: Int32? = nil, isLocallyRestored: Bool = false, edits: [WhitegramHistoryEdit] = [], isShortened: Bool = false) {
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.isLocallyRestored = isLocallyRestored
        self.edits = edits
        self.isShortened = isShortened
    }

    public init(decoder: PostboxDecoder) {
        self.isDeleted = decoder.decodeBoolForKey("d", orElse: false)
        self.deletedAt = decoder.decodeOptionalInt32ForKey("dt")
        self.isLocallyRestored = decoder.decodeBoolForKey("r", orElse: false)
        self.edits = decoder.decodeObjectArrayWithDecoderForKey("e")
        self.isShortened = decoder.decodeBoolForKey("s", orElse: false)
    }

    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeBool(self.isDeleted, forKey: "d")
        if let deletedAt { encoder.encodeInt32(deletedAt, forKey: "dt") }
        else { encoder.encodeNil(forKey: "dt") }
        encoder.encodeBool(self.isLocallyRestored, forKey: "r")
        encoder.encodeObjectArray(self.edits, forKey: "e")
        encoder.encodeBool(self.isShortened, forKey: "s")
    }

    public func withDeletion(_ deleted: Bool, at date: Int32? = nil) -> WhitegramHistoryMessageAttribute {
        return WhitegramHistoryMessageAttribute(isDeleted: deleted, deletedAt: deleted ? (self.deletedAt ?? date) : nil, isLocallyRestored: !deleted || self.isLocallyRestored, edits: self.edits, isShortened: self.isShortened)
    }

    public func withoutEdits() -> WhitegramHistoryMessageAttribute {
        return WhitegramHistoryMessageAttribute(isDeleted: self.isDeleted, deletedAt: self.deletedAt, isLocallyRestored: self.isLocallyRestored, isShortened: self.isShortened)
    }

    public func appending(_ edit: WhitegramHistoryEdit) -> WhitegramHistoryMessageAttribute {
        if let last = self.edits.last, last.text == edit.text && last.entities == edit.entities && last.date == edit.date { return self }
        return WhitegramHistoryMessageAttribute(isDeleted: self.isDeleted, deletedAt: self.deletedAt, isLocallyRestored: self.isLocallyRestored, edits: self.edits + [edit], isShortened: self.isShortened)
    }

    public func withShortening(_ shortened: Bool) -> WhitegramHistoryMessageAttribute {
        return WhitegramHistoryMessageAttribute(isDeleted: self.isDeleted, deletedAt: self.deletedAt,
            isLocallyRestored: self.isLocallyRestored, edits: self.edits, isShortened: shortened)
    }

    public var associatedPeerIds: [PeerId] {
        return Array(Set(self.edits.flatMap { edit in
            edit.entities.compactMap { entity -> PeerId? in
                if case let .TextMention(peerId) = entity.type { return peerId }
                return nil
            }
        }))
    }

    public var associatedMediaIds: [MediaId] {
        return Array(Set(self.edits.flatMap { edit in
            edit.entities.compactMap { entity -> MediaId? in
                if case let .CustomEmoji(_, fileId) = entity.type { return MediaId(namespace: Namespaces.Media.CloudFile, id: fileId) }
                return nil
            }
        }))
    }
}

public extension Message {
    var whitegramHistoryAttribute: WhitegramHistoryMessageAttribute? {
        return self.attributes.first(where: { $0 is WhitegramHistoryMessageAttribute }) as? WhitegramHistoryMessageAttribute
    }
}
