import Foundation

protocol WhitegramBackendValidatable {
    func validateResponse() throws
}

enum WhitegramBackendDecoding {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let value = try JSONDecoder().decode(type, from: data)
        try (value as? WhitegramBackendValidatable)?.validateResponse()
        return value
    }
}

extension WhitegramProfileAbout: WhitegramBackendValidatable {
    func validateResponse() throws {
        guard text.count <= Self.maximumLength, entities.count <= 512, entities.allSatisfy({ $0.isValid(in: text) }) else {
            throw WhitegramBackendError.invalidResponse
        }
    }
}

extension WhitegramProfileQuoteEnvelope: WhitegramBackendValidatable {
    func validateResponse() throws {
        if let quote {
            guard quote.text.utf8.count <= 64 * 1024, quote.entities.count <= 512,
                  quote.entities.allSatisfy({ $0.isValid(in: quote.text) }) else { throw WhitegramBackendError.invalidResponse }
        }
    }
}

extension WhitegramProfileWallState: WhitegramBackendValidatable {
    func validateResponse() throws {
        guard messages.count <= 10000, Set(messages.map(\.id)).count == messages.count,
              nextAllowedAt.map({ (0...253402300799).contains($0) }) ?? true else { throw WhitegramBackendError.invalidResponse }
        for message in messages {
            guard !message.id.isEmpty, message.id.utf8.count <= 1024, message.wallOwnerId > 0, message.authorId > 0,
                  (0...253402300799).contains(message.timestamp), message.text.utf8.count <= 64 * 1024,
                  message.authorName.utf8.count <= 1024, message.editedAt.map({ (0...253402300799).contains($0) }) ?? true,
                  message.entities.count <= 512, message.entities.allSatisfy({ $0.isValid(in: message.text) }) else {
                throw WhitegramBackendError.invalidResponse
            }
        }
    }
}

extension WhitegramProfileReactions: WhitegramBackendValidatable {
    func validateResponse() throws {
        guard emojis.count <= 128, Set(emojis).count == emojis.count,
              emojis.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }), counts.count <= 128, myVotes.count <= 128,
              counts.values.allSatisfy({ $0 >= 0 }) else {
            throw WhitegramBackendError.invalidResponse
        }
    }
}

extension WhitegramProfileLyricEnvelope: WhitegramBackendValidatable {
    func validateResponse() throws {
        if let lyric {
            let fields = [lyric.songTitle, lyric.artist, lyric.songUrl, lyric.line1, lyric.line2, lyric.line3, lyric.line4]
            guard fields.allSatisfy({ $0.utf8.count <= 16384 }), lyric.updatedAt.map({ (0...253402300799).contains($0) }) ?? true else {
                throw WhitegramBackendError.invalidResponse
            }
        }
    }
}

extension WhitegramProfileSongsEnvelope: WhitegramBackendValidatable {
    func validateResponse() throws {
        guard results.count <= 1000, Set(results.map(\.id)).count == results.count,
              results.allSatisfy({ $0.id > 0 && $0.title.utf8.count <= 4096 && $0.artist.utf8.count <= 4096 && $0.url.utf8.count <= 8192 }) else {
            throw WhitegramBackendError.invalidResponse
        }
    }
}

extension WhitegramProfileBlockedEnvelope: WhitegramBackendValidatable {
    func validateResponse() throws {
        guard blocked.count <= 10000, Set(blocked.map(\.userId)).count == blocked.count,
              blocked.allSatisfy({ $0.userId > 0 && (0...253402300799).contains($0.createdAt) }) else { throw WhitegramBackendError.invalidResponse }
    }
}

extension WhitegramProfileBadge: WhitegramBackendValidatable {
    func validateResponse() throws {
        guard [role, badgeText, verificationText, titleIcon].compactMap({ $0 }).allSatisfy({ $0.utf8.count <= 4096 }) else { throw WhitegramBackendError.invalidResponse }
        if let presence {
            guard !presence.kind.isEmpty, presence.kind.utf8.count <= 128,
                  presence.text.map({ $0.utf8.count <= 16384 }) ?? true,
                  presence.updatedAt.map({ (0...253402300799).contains($0) }) ?? true,
                  presence.expiresAt.map({ (0...253402300799).contains($0) }) ?? true else { throw WhitegramBackendError.invalidResponse }
        }
    }
}
