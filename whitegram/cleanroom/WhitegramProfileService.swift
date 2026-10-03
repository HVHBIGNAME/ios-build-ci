import Foundation

enum WhitegramProfileResource: String, CaseIterable {
    case about, badge, color, lyric, quote, scene, reactions, wall, registration

    var path: String {
        switch self {
        case .reactions: return "/v1/profile-reactions/state"
        case .wall: return "/v1/wall"
        case .registration: return "/v1/registration-date"
        default: return "/v1/profile/" + rawValue
        }
    }

    var cacheLifetime: TimeInterval {
        switch self {
        case .about, .scene: return 120
        case .badge, .color: return 5
        case .wall: return 60
        case .registration: return 600
        case .lyric, .quote, .reactions: return 0
        }
    }
}

enum WhitegramProfileRequests {
    struct Enabled: Encodable { let enabled: Bool }
    struct WallSend: Encodable { let ownerId: Int64; let text: String; let entities: [WhitegramProfileTextEntity]; let authorName: String }
    struct WallEdit: Encodable { let ownerId: Int64; let id: String; let text: String; let entities: [WhitegramProfileTextEntity] }
    struct WallDelete: Encodable { let ownerId: Int64; let ids: [String] }
    struct WallUser: Encodable { let userId: Int64; let wallOwnerId: Int64 }
    struct Reactions: Encodable { let enabled: Bool; let emojis: [String] }
    struct Vote: Encodable {
        let targetUserId: Int64
        let emoji: String
        enum CodingKeys: String, CodingKey { case targetUserId = "target_user_id", emoji }
    }

    static func encoded<T: Encodable>(_ value: T) throws -> Data { return try JSONEncoder().encode(value) }

    static func validate(text: String, entities: [WhitegramProfileTextEntity], allowEmpty: Bool = false) throws {
        guard (allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
              text.utf8.count <= 64 * 1024, entities.count <= 512, entities.allSatisfy({ $0.isValid(in: text) }) else {
            throw WhitegramBackendError.invalidRequest
        }
    }
}

final class WhitegramProfileService {
    static let updated = Notification.Name("WhitegramBackendProfileUpdated")
    private struct CacheEntry { let data: Data; let date: Date; let session: WhitegramBackendSession }
    let client: WhitegramBackendClient
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var cacheEpoch: UInt64 = 0
    private let now: () -> Date

    init(client: WhitegramBackendClient, now: @escaping () -> Date = Date.init) { self.client = client; self.now = now }

    @discardableResult
    func fetch<T: Decodable>(_ type: T.Type, resource: WhitegramProfileResource, userId: Int64, force: Bool = false,
                             completion: @escaping (Result<T, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        guard userId > 0 else { return WhitegramBackendCancellation.failure(.invalidRequest, completion: completion) }
        let startingSession: WhitegramBackendSession
        do {
            guard let session = try client.sessions.load(userId: client.userId) else { throw WhitegramBackendError.missingSession }
            try session.validate(userId: client.userId, now: now())
            try client.access.require(userId: client.userId, path: resource.path, now: now())
            startingSession = session
        } catch { return WhitegramBackendCancellation.failure(error as? WhitegramBackendError ?? .invalidResponse, completion: completion) }
        let key = resource.rawValue + ":\(userId)"
        lock.lock()
        let cached = cache[key]
        let epoch = cacheEpoch
        lock.unlock()
        if !force, let cached, (0..<resource.cacheLifetime).contains(now().timeIntervalSince(cached.date)) {
            do {
                if startingSession == cached.session {
                    try cached.session.validate(userId: client.userId, now: now())
                    let value = try WhitegramBackendDecoding.decode(T.self, from: cached.data)
                    let cancellation = WhitegramBackendCancellation()
                    DispatchQueue.main.async { [self] in
                        do {
                            guard cancellation.claimCompletion() else { return }
                            if cancellation.isCancelled { throw WhitegramBackendError.cancelled }
                            guard try client.sessions.load(userId: client.userId) == cached.session else { throw WhitegramBackendError.sessionChanged }
                            try cached.session.validate(userId: client.userId, now: now())
                            try client.access.require(userId: client.userId, path: resource.path, now: now())
                            lock.lock()
                            let unchanged = epoch == cacheEpoch
                            lock.unlock()
                            guard unchanged else { throw WhitegramBackendError.staleResponse }
                            completion(.success(value))
                        } catch let error as WhitegramBackendError { completion(.failure(error)) }
                        catch { completion(.failure(.invalidResponse)) }
                    }
                    return cancellation
                }
            } catch { /* A cache miss goes through the normal authenticated request path. */ }
        }
        let query = [URLQueryItem(name: resource == .wall ? "owner_id" : "user_id", value: String(userId))]
        return client.raw(path: resource.path, query: query) { [weak self] result in
            completion(result.flatMap { response in
                do {
                    let value = try WhitegramBackendDecoding.decode(T.self, from: response.data)
                    if let wall = value as? WhitegramProfileWallState, !wall.messages.allSatisfy({ $0.wallOwnerId == userId }) { throw WhitegramBackendError.invalidResponse }
                    if let self {
                        guard try self.client.sessions.load(userId: self.client.userId) == startingSession else { throw WhitegramBackendError.sessionChanged }
                        self.lock.lock()
                        guard epoch == self.cacheEpoch else { self.lock.unlock(); throw WhitegramBackendError.staleResponse }
                        if self.cache.count >= 128, let oldest = self.cache.min(by: { $0.value.date < $1.value.date })?.key { self.cache.removeValue(forKey: oldest) }
                        self.cache[key] = CacheEntry(data: response.data, date: self.now(), session: startingSession)
                        self.lock.unlock()
                    }
                    return .success(value)
                } catch { return .failure(error as? WhitegramBackendError ?? .invalidResponse) }
            })
        }
    }

    @discardableResult
    func save<T: Encodable>(_ value: T, path: String, completion: @escaping (Result<Void, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        do {
            return client.raw(path: path, method: "POST", body: try WhitegramProfileRequests.encoded(value)) { [weak self] result in
                if case .success = result, let self {
                    self.didMutate()
                }
                completion(result.map { _ in Void() })
            }
        } catch {
            let cancellation = WhitegramBackendCancellation()
            DispatchQueue.main.async { completion(.failure(cancellation.isCancelled ? .cancelled : .invalidRequest)) }
            return cancellation
        }
    }

    private func didMutate() {
        lock.lock()
        cacheEpoch &+= 1
        cache.removeAll()
        lock.unlock()
        NotificationCenter.default.post(name: Self.updated, object: nil, userInfo: ["accountId": client.userId])
    }

    private func mutate<T: Decodable>(_ type: T.Type, path: String, body: Data,
                                      completion: @escaping (Result<T, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        return client.request(type, path: path, method: "POST", body: body) { [weak self] result in
            if case .success = result { self?.didMutate() }
            completion(result)
        }
    }

    func saveAbout(_ value: WhitegramProfileAbout, completion: @escaping (Result<Void, WhitegramBackendError>) -> Void) throws -> WhitegramBackendTask {
        guard value.text.count <= WhitegramProfileAbout.maximumLength else { throw WhitegramBackendError.invalidRequest }
        try WhitegramProfileRequests.validate(text: value.text, entities: value.entities, allowEmpty: true)
        return save(value, path: "/v1/profile/about", completion: completion)
    }

    func saveQuote(_ value: WhitegramProfileQuote, completion: @escaping (Result<Void, WhitegramBackendError>) -> Void) throws -> WhitegramBackendTask {
        try WhitegramProfileRequests.validate(text: value.text, entities: value.entities, allowEmpty: true)
        return save(WhitegramProfileQuoteEnvelope(quote: value), path: "/v1/profile/quote", completion: completion)
    }

    func saveLyric(_ value: WhitegramProfileLyric, completion: @escaping (Result<Void, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        return save(WhitegramProfileLyricEnvelope(lyric: value), path: "/v1/profile/lyric", completion: completion)
    }

    func searchSongs(_ query: String, completion: @escaping (Result<[WhitegramProfileSong], WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        return client.request(WhitegramProfileSongsEnvelope.self, path: "/v1/lyrics/search", query: [URLQueryItem(name: "q", value: query)]) { completion($0.map { $0.results }) }
    }

    func lyrics(song: WhitegramProfileSong, completion: @escaping (Result<String, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        return client.request(WhitegramProfileLyricsEnvelope.self, path: "/v1/lyrics/text", query: [URLQueryItem(name: "id", value: String(song.id))]) { completion($0.map { $0.lyrics }) }
    }

    func send(ownerId: Int64, text: String, entities: [WhitegramProfileTextEntity], authorName: String,
              completion: @escaping (Result<WhitegramProfileWallState, WhitegramBackendError>) -> Void) throws -> WhitegramBackendTask {
        guard ownerId > 0, !authorName.isEmpty, authorName.utf8.count <= 1024 else { throw WhitegramBackendError.invalidRequest }
        try WhitegramProfileRequests.validate(text: text, entities: entities)
        let value = WhitegramProfileRequests.WallSend(ownerId: ownerId, text: text, entities: entities, authorName: authorName)
        return mutate(WhitegramProfileWallState.self, path: "/v1/wall/message", body: try WhitegramProfileRequests.encoded(value), completion: completion)
    }

    func edit(ownerId: Int64, messageId: String, text: String, entities: [WhitegramProfileTextEntity],
              completion: @escaping (Result<WhitegramProfileWallState, WhitegramBackendError>) -> Void) throws -> WhitegramBackendTask {
        guard ownerId > 0, !messageId.isEmpty, messageId.utf8.count <= 1024 else { throw WhitegramBackendError.invalidRequest }
        try WhitegramProfileRequests.validate(text: text, entities: entities)
        let value = WhitegramProfileRequests.WallEdit(ownerId: ownerId, id: messageId, text: text, entities: entities)
        return mutate(WhitegramProfileWallState.self, path: "/v1/wall/edit", body: try WhitegramProfileRequests.encoded(value), completion: completion)
    }

    func delete(ownerId: Int64, ids: [String], completion: @escaping (Result<WhitegramProfileWallState, WhitegramBackendError>) -> Void) throws -> WhitegramBackendTask {
        guard ownerId > 0, !ids.isEmpty, ids.count <= 1000, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else { throw WhitegramBackendError.invalidRequest }
        return mutate(WhitegramProfileWallState.self, path: "/v1/wall/delete",
            body: try WhitegramProfileRequests.encoded(WhitegramProfileRequests.WallDelete(ownerId: ownerId, ids: ids)), completion: completion)
    }

    func blocked(ownerId: Int64, completion: @escaping (Result<[WhitegramProfileBlockedUser], WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        return client.request(WhitegramProfileBlockedEnvelope.self, path: "/v1/wall/blocked", query: [URLQueryItem(name: "owner_id", value: String(ownerId))]) { completion($0.map { $0.blocked }) }
    }

    func block(_ blocked: Bool, userId: Int64, ownerId: Int64, completion: @escaping (Result<Void, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        return save(WhitegramProfileRequests.WallUser(userId: userId, wallOwnerId: ownerId), path: blocked ? "/v1/wall/block" : "/v1/wall/unblock", completion: completion)
    }

    func vote(userId: Int64, emoji: String, completion: @escaping (Result<WhitegramProfileReactions, WhitegramBackendError>) -> Void) throws -> WhitegramBackendTask {
        guard userId > 0, !emoji.isEmpty, emoji.utf8.count <= 128 else { throw WhitegramBackendError.invalidRequest }
        return mutate(WhitegramProfileReactions.self, path: "/v1/profile-reactions/vote",
            body: try WhitegramProfileRequests.encoded(WhitegramProfileRequests.Vote(targetUserId: userId, emoji: emoji)), completion: completion)
    }
}
