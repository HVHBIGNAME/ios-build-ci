import Foundation

struct WhitegramProfilePresenceUpdate: Codable, Equatable {
    let kind: String
    let text: String?
    let extra: WhitegramProfilePresence.Extra?
    let exact: Bool

    static func radio(station: WhitegramRadioStation, track: WhitegramRadioTrack?, precise: Bool) -> WhitegramProfilePresenceUpdate {
        let text = [track?.artist, track?.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
        return WhitegramProfilePresenceUpdate(kind: "radio", text: precise ? (text.isEmpty ? station.name : text) : nil,
            extra: precise ? WhitegramProfilePresence.Extra(station: station.name, artist: track?.artist,
                title: track?.title, coverUrl: track?.coverURL?.absoluteString) : nil, exact: precise)
    }
}

final class WhitegramProfilePresencePublisher {
    private let client: WhitegramBackendClient
    private let now: () -> Date
    private let updated: (WhitegramBackendError?) -> Void
    private var desired: WhitegramProfilePresenceUpdate?
    private var lastPublished: WhitegramProfilePresenceUpdate?
    private var lastPublishedAt: Date?
    private var mayHavePublished = false
    private var retryAt: Date?
    private var task: WhitegramBackendTask?
    var userId: Int64 { return client.userId }

    init(client: WhitegramBackendClient, now: @escaping () -> Date = Date.init, updated: @escaping (WhitegramBackendError?) -> Void) {
        self.client = client
        self.now = now
        self.updated = updated
    }

    func update(_ value: WhitegramProfilePresenceUpdate?) {
        precondition(Thread.isMainThread)
        if value != desired { retryAt = nil }
        desired = value
        publishIfNeeded()
    }

    private func publishIfNeeded() {
        guard task == nil, retryAt.map({ $0 <= now() }) ?? true else { return }
        let value = desired
        if value == nil && !mayHavePublished { return }
        if let value, value == lastPublished, let lastPublishedAt, now().timeIntervalSince(lastPublishedAt) < 25 { return }
        do {
            let data = try value.map { try JSONEncoder().encode($0) }
            if value != nil { mayHavePublished = true }
            task = client.raw(path: "/v1/presence", method: value == nil ? "DELETE" : "POST", body: data) { [self] result in
                task = nil
                switch result {
                case .success:
                    lastPublished = value
                    lastPublishedAt = now()
                    mayHavePublished = value != nil
                    retryAt = nil
                    updated(nil)
                case let .failure(error):
                    let delay: TimeInterval
                    if case let .http(429, retryAfter) = error { delay = retryAfter ?? 60 }
                    else { delay = 25 }
                    retryAt = now().addingTimeInterval(delay)
                    updated(error)
                }
                if desired != value {
                    retryAt = nil
                    publishIfNeeded()
                }
            }
        } catch {
            retryAt = now().addingTimeInterval(25)
            updated(.invalidRequest)
        }
    }
}
