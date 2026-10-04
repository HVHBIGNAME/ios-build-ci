import Foundation
#if canImport(TelegramCore)
import TelegramCore
#endif

struct WhitegramProfileStreakEvent: Encodable, Equatable {
    let peerId: Int64
    let timestamp: Int32
    let timezoneOffset: Int
    enum CodingKeys: String, CodingKey {
        case peerId = "peer_id", timestamp = "event_timestamp", timezoneOffset = "timezone_offset"
    }

    init(peerId: Int64, timestamp: Int32, timeZone: TimeZone = .current) {
        self.peerId = peerId
        self.timestamp = timestamp
        timezoneOffset = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(timestamp)))
    }
}

struct WhitegramProfileStreakList: Decodable { let streaks: [WhitegramProfileStreak] }

final class WhitegramProfileStreakService {
    let client: WhitegramBackendClient
    private let profile: WhitegramProfileService

    init(client: WhitegramBackendClient) {
        self.client = client
        self.profile = WhitegramProfileService(client: client)
    }

    func list(at date: Date = Date(), timeZone: TimeZone = .current,
              completion: @escaping (Result<[WhitegramProfileStreak], WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        return client.request(WhitegramProfileStreakList.self, path: "/v1/streak/list",
            query: [URLQueryItem(name: "timezone_offset", value: String(timeZone.secondsFromGMT(for: date)))]) { result in
            completion(result.flatMap { list in
                guard list.streaks.count <= 10000, Set(list.streaks.map(\.peerId)).count == list.streaks.count,
                      list.streaks.allSatisfy(\.isValid) else { return .failure(.invalidResponse) }
                return .success(list.streaks)
            })
        }
    }

    func state(peerId: Int64, completion: @escaping (Result<WhitegramProfileStreak, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        return client.request(WhitegramProfileStreak.self, path: "/v1/streak/state",
            query: [URLQueryItem(name: "peer_id", value: String(peerId))]) { result in
            completion(result.flatMap { state in
                guard state.isValid, state.peerId == peerId else { return .failure(.invalidResponse) }
                return .success(state)
            })
        }
    }

    func setEnabled(_ enabled: Bool, completion: @escaping (Result<Void, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        return profile.save(WhitegramProfileRequests.Enabled(enabled: enabled), path: "/v1/streak/settings", completion: completion)
    }

    func report(_ event: WhitegramBackendMessageEvent, timeZone: TimeZone = .current,
                completion: @escaping (Result<Void, WhitegramBackendError>) -> Void) -> WhitegramBackendTask {
        do {
            guard event.accountId == client.userId, event.peerId > 0, event.peerId != client.userId,
                  event.messageId > 0, event.timestamp > 0 else { throw WhitegramBackendError.invalidRequest }
            let body = try JSONEncoder().encode(WhitegramProfileStreakEvent(peerId: event.peerId, timestamp: event.timestamp, timeZone: timeZone))
            return client.raw(path: event.direction == .sent ? "/v1/streak/event" : "/v1/streak/received", method: "POST", body: body) { completion($0.map { _ in Void() }) }
        } catch {
            let cancellation = WhitegramBackendCancellation()
            DispatchQueue.main.async { completion(.failure(cancellation.isCancelled ? .cancelled : .invalidRequest)) }
            return cancellation
        }
    }
}

extension WhitegramProfileStreak {
    var isValid: Bool {
        return peerId > 0 && streakDays >= 0 && talkingDays >= 0
            && (serverFlameLevel.map({ $0 >= 0 }) ?? true)
            && (nextMilestone.map({ $0 >= 0 }) ?? true)
            && (reachedMilestone.map({ $0 >= 0 }) ?? true)
    }
}
