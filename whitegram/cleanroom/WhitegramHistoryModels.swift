import Foundation

public enum WhitegramHistoryEvent: String, Codable, CaseIterable {
    case received
    case deleted
    case edited
}

public struct WhitegramHistoryMessageId: Equatable, Hashable {
    public let peerId: String
    public let namespace: Int32
    public let id: Int32

    public init(peerId: String, namespace: Int32, id: Int32) {
        self.peerId = peerId
        self.namespace = namespace
        self.id = id
    }
}

public enum WhitegramHistoryScope: Equatable {
    case account
    case peer(String)
    case message(WhitegramHistoryMessageId)

    public var peerId: String? {
        switch self {
        case .account: return nil
        case let .peer(id): return id
        case let .message(id): return id.peerId
        }
    }

    public func contains(_ entry: WhitegramHistoryEntry) -> Bool {
        switch self {
        case .account: return true
        case let .peer(id): return entry.peerId == id
        case let .message(id): return entry.messageIdentity == id
        }
    }
}

public enum WhitegramHistoryOrder: CaseIterable, Equatable {
    case originalTime
    case captureTime
}

public struct WhitegramHistoryQuery: Equatable {
    public var scope: WhitegramHistoryScope
    public var event: WhitegramHistoryEvent?
    public var text: String
    public var order: WhitegramHistoryOrder

    public init(scope: WhitegramHistoryScope = .account, event: WhitegramHistoryEvent? = nil, text: String = "", order: WhitegramHistoryOrder = .originalTime) {
        self.scope = scope
        self.event = event
        self.text = text
        self.order = order
    }

    public func matches(_ entry: WhitegramHistoryEntry) -> Bool {
        guard self.scope.contains(entry), self.event == nil || entry.event == self.event else { return false }
        let text = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return true }
        let fields = [entry.text, entry.peerId, String(entry.messageId), entry.peerTitle ?? "", entry.authorName ?? "", entry.authorId ?? ""]
            + (entry.media ?? []).map { $0.fileName ?? "" }
        return fields.contains { $0.localizedCaseInsensitiveContains(text) }
    }

    public func apply(to entries: [WhitegramHistoryEntry]) -> [WhitegramHistoryEntry] {
        return entries.filter(self.matches).sorted { lhs, rhs in
            if self.order == .originalTime, lhs.messageDate != rhs.messageDate {
                return lhs.messageDate > rhs.messageDate
            }
            if lhs.capturedAt != rhs.capturedAt { return lhs.capturedAt > rhs.capturedAt }
            return lhs.key < rhs.key
        }
    }
}

/// Describes the attachment as observed. It is not a downloadable media reference or a saved payload.
public struct WhitegramHistoryMedia: Codable, Equatable {
    public enum Kind: String, Codable {
        case photo, video, videoMessage, audio, voice, sticker, file, webpage, poll, other
    }

    public let kind: Kind
    public let mediaId: String?
    public let fileName: String?
    public let mimeType: String?
    public let size: Int64?
    public let width: Int32?
    public let height: Int32?
    public let duration: Double?

    public init(kind: Kind, mediaId: String? = nil, fileName: String? = nil, mimeType: String? = nil, size: Int64? = nil, width: Int32? = nil, height: Int32? = nil, duration: Double? = nil) {
        self.kind = kind
        self.mediaId = mediaId
        self.fileName = fileName
        self.mimeType = mimeType
        self.size = size
        self.width = width
        self.height = height
        self.duration = duration
    }
}

public struct WhitegramHistoryEntry: Codable, Equatable {
    public let key: String
    public let accountId: String
    public let peerId: String
    public let namespace: Int32
    public let messageId: Int32
    public let revision: UInt32
    public let messageDate: Int32
    public let capturedAt: Double
    public let event: WhitegramHistoryEvent
    public let text: String
    public let authorId: String?
    public let outgoing: Bool
    public let mediaCount: Int
    // Optional additions keep existing v1 archives readable without inventing missing metadata.
    public let peerTitle: String?
    public let authorName: String?
    public let editedAt: Int32?
    public let textTruncated: Bool?
    public let media: [WhitegramHistoryMedia]?

    public var messageIdentity: WhitegramHistoryMessageId {
        return WhitegramHistoryMessageId(peerId: self.peerId, namespace: self.namespace, id: self.messageId)
    }

    public init(accountId: String, peerId: String, namespace: Int32, messageId: Int32, revision: UInt32, messageDate: Int32, capturedAt: Double, event: WhitegramHistoryEvent, text: String, authorId: String?, outgoing: Bool, mediaCount: Int, peerTitle: String? = nil, authorName: String? = nil, editedAt: Int32? = nil, textTruncated: Bool? = nil, media: [WhitegramHistoryMedia]? = nil) {
        self.key = "\(peerId):\(namespace):\(messageId):\(event.rawValue):\(revision)"
        self.accountId = accountId
        self.peerId = peerId
        self.namespace = namespace
        self.messageId = messageId
        self.revision = revision
        self.messageDate = messageDate
        self.capturedAt = capturedAt
        self.event = event
        self.text = text
        self.authorId = authorId
        self.outgoing = outgoing
        self.mediaCount = mediaCount
        self.peerTitle = peerTitle
        self.authorName = authorName
        self.editedAt = editedAt
        self.textTruncated = textTruncated
        self.media = media
    }
}

func whitegramHistoryBoundedString(_ value: String, maximumBytes: Int) -> String {
    let utf8 = value.utf8
    guard utf8.count > maximumBytes else { return value }
    var end = utf8.index(utf8.startIndex, offsetBy: maximumBytes)
    while end > utf8.startIndex && utf8[end] & 0xc0 == 0x80 {
        end = utf8.index(before: end)
    }
    return String(decoding: utf8[..<end], as: UTF8.self)
}
