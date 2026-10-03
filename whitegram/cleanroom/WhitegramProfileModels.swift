import Foundation

struct WhitegramProfileTextEntity: Codable, Equatable {
    let offset: Int
    let length: Int
    let type: String
    let url: String?
    let documentId: Int64?

    func isValid(in text: String) -> Bool {
        let count = text.utf16.count
        guard offset >= 0 && length > 0 && offset <= count && length <= count - offset else { return false }
        return Range(NSRange(location: offset, length: length), in: text) != nil
    }
}

struct WhitegramProfileAbout: Codable, Equatable {
    static let maximumLength = 1200
    var enabled: Bool
    var text: String
    var entities: [WhitegramProfileTextEntity]
    var image: String?
}

enum WhitegramProfileLyricAnimation: Int, Codable, CaseIterable {
    case none = 0, typing, scramble, fadeSlide, softGlow
}

struct WhitegramProfileLyric: Codable, Equatable {
    var enabled: Bool
    var songTitle: String
    var artist: String
    var songUrl: String
    var line1: String
    var line2: String
    var line3: String
    var line4: String
    var animation: WhitegramProfileLyricAnimation
    var updatedAt: Int64?
    var lines: [String] { return [line1, line2, line3, line4].filter { !$0.isEmpty } }
}

struct WhitegramProfileSong: Decodable, Equatable {
    let id: Int
    let title: String
    let artist: String
    let url: String
    let thumbnailUrl: String?
}

struct WhitegramProfileQuote: Codable, Equatable {
    var enabled: Bool
    var text: String
    var entities: [WhitegramProfileTextEntity]
    var updatedAt: Int64?
}

struct WhitegramProfilePresence: Codable, Equatable {
    struct Extra: Codable, Equatable {
        var station: String?
        var artist: String?
        var title: String?
        var coverUrl: String?
    }
    let kind: String
    let text: String?
    let icon: String?
    let extra: Extra?
    let updatedAt: Int64?
    let expiresAt: Int64?

    func isCurrent(at date: Date) -> Bool {
        guard let expiresAt else { return false }
        return Double(expiresAt) > date.timeIntervalSince1970
    }
}

struct WhitegramProfileBadge: Codable, Equatable {
    let enabled: Bool
    let role: String?
    let presence: WhitegramProfilePresence?
    let badgeText: String?
    let verificationText: String?
    let granted: Bool?
    let titleIcon: String?
}

struct WhitegramProfileColor: Codable, Equatable {
    var nameColor: Int32
    var nameBgEmojiId: Int64
    var profileColor: Int32
    var profileBgEmojiId: Int64
    var isLocalPremium: Bool
    var emojiStatusFileId: Int64
}

enum WhitegramProfileScene: String, Codable, CaseIterable {
    case none, snow, stars, clouds, terminal
}

struct WhitegramProfileSceneState: Codable, Equatable { var scene: WhitegramProfileScene }

struct WhitegramProfileReactions: Codable, Equatable {
    let enabled: Bool
    let emojis: [String]
    let counts: [String: Int]
    let myVotes: [String: Bool]
}

struct WhitegramProfileWallMessage: Codable, Equatable {
    let id: String
    let wallOwnerId: Int64
    let authorId: Int64
    let authorName: String
    let text: String
    let entities: [WhitegramProfileTextEntity]
    let timestamp: Int64
    let editedAt: Int64?
}

struct WhitegramProfileWallState: Codable, Equatable {
    let enabled: Bool
    let messages: [WhitegramProfileWallMessage]
    let nextAllowedAt: Int64?
    let blocked: Bool

    func canPost(at date: Date) -> Bool {
        return enabled && !blocked && (nextAllowedAt.map { Double($0) <= date.timeIntervalSince1970 } ?? true)
    }
}

struct WhitegramProfileBlockedUser: Codable, Equatable { let userId: Int64; let createdAt: Int64 }

struct WhitegramProfileStreak: Codable, Equatable {
    let streakDays: Int
    let isActiveToday: Bool
    let peerId: Int64
    let talkingDays: Int
    let serverFlameLevel: Int?
    let nextMilestone: Int?
    let reachedMilestone: Int?
    enum CodingKeys: String, CodingKey {
        case streakDays, isActiveToday, peerId, talkingDays, serverFlameLevel = "flameLevel", nextMilestone, reachedMilestone
    }
}

struct WhitegramProfileLyricEnvelope: Codable { let lyric: WhitegramProfileLyric? }
struct WhitegramProfileQuoteEnvelope: Codable { let quote: WhitegramProfileQuote? }
struct WhitegramProfileSongsEnvelope: Decodable { let results: [WhitegramProfileSong] }
struct WhitegramProfileLyricsEnvelope: Decodable { let lyrics: String }
struct WhitegramProfileBlockedEnvelope: Decodable { let blocked: [WhitegramProfileBlockedUser] }
