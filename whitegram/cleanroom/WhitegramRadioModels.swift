import Foundation

struct WhitegramRadioStation: Equatable {
    let id: String
    let name: String
    let streamURL: URL
    let logoURL: URL
    let emgChannel: String?
    let logoNeedsDarkBackground: Bool

    static let all: [WhitegramRadioStation] = [
        WhitegramRadioStation(id: "europaplus", name: "Европа Плюс",
            streamURL: URL(string: "http://ep256.hostingradio.ru:8052/europaplus256.mp3")!,
            logoURL: URL(string: "https://admin.europaplus.ru/mf/p/334746/front_channels/000/000032/cover/b2f61bc6896bb1cec5a29a2de38adffa.webp")!, emgChannel: "europaplus", logoNeedsDarkBackground: false),
        WhitegramRadioStation(id: "dorognoe", name: "Дорожное радио",
            streamURL: URL(string: "http://dorognoe.hostingradio.ru:8000/dorognoe")!,
            logoURL: URL(string: "https://www.google.com/s2/favicons?domain=dorognoe.ru&sz=256")!, emgChannel: "dorognoe", logoNeedsDarkBackground: false),
        WhitegramRadioStation(id: "radiorecord", name: "Radio Record",
            streamURL: URL(string: "https://radiorecord.hostingradio.ru/rr_main96.aacp")!,
            logoURL: URL(string: "https://www.radiorecord.ru/icons/apple-touch-icon.png")!, emgChannel: nil, logoNeedsDarkBackground: false),
        WhitegramRadioStation(id: "z100", name: "Z100",
            streamURL: URL(string: "https://stream.revma.ihrhls.com/zc1469")!,
            logoURL: URL(string: "https://i.iheart.com/v3/re/assets.brands/5e7b5d50bee47a8a2b396059?ops=gravity(%22center%22),contain(360,360)&quality=80")!, emgChannel: nil, logoNeedsDarkBackground: true),
        WhitegramRadioStation(id: "kroq", name: "KROQ",
            streamURL: URL(string: "http://live.amperwave.net/direct/audacy-kroqfmaac-imc")!,
            logoURL: URL(string: "https://bloximages.newyork1.vip.townnews.com/insideradio.com/content/tncms/assets/v3/editorial/6/0b/60be09e8-9adb-11ea-9359-abd53ad48e69/5ec597dadab89.image.jpg?resize=375%2C325")!, emgChannel: nil, logoNeedsDarkBackground: false)
    ]
}

struct WhitegramRadioTrack: Equatable {
    let artist: String
    let title: String
    let coverURL: URL?
}

enum WhitegramRadioMetadata {
    static let socketURL = URL(string: "wss://meta.hostingradio.ru/emg/ws?format=native")!
    private struct Subscription: Encodable {
        let fetch: [String: [String]]
        let subscribe: [String: [String]]
    }
    private struct Envelope: Decodable {
        struct Track: Decodable {
            let artist: String
            let title: String
            let coverImageUrl300: String?
            let coverImageUrl600: String?
        }
        let current: [String: Track]
    }

    static func subscription(channel: String) throws -> Data {
        guard WhitegramRadioStation.all.contains(where: { $0.emgChannel == channel }) else { throw WhitegramBackendError.invalidRequest }
        return try JSONEncoder().encode(Subscription(fetch: ["current": [channel]], subscribe: ["current": [channel]]))
    }

    static func emg(_ data: Data, channel: String) throws -> WhitegramRadioTrack? {
        guard data.count <= 256 * 1024 else { throw WhitegramBackendError.responseTooLarge }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let track = envelope.current[channel], !track.title.isEmpty else { return nil }
        let cover = (track.coverImageUrl600 ?? track.coverImageUrl300).flatMap(URL.init(string:))
        return WhitegramRadioTrack(artist: track.artist, title: track.title, coverURL: cover?.scheme == "https" ? cover : nil)
    }

    static func icy(_ input: String) -> WhitegramRadioTrack? {
        guard input.utf8.count <= 64 * 1024 else { return nil }
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = text.range(of: "StreamTitle='", options: .caseInsensitive), let end = text.range(of: "';", range: start.upperBound..<text.endIndex) {
            text = String(text[start.upperBound..<end.lowerBound])
        }
        guard !text.isEmpty else { return nil }
        if let separator = text.range(of: " - ") {
            return WhitegramRadioTrack(artist: String(text[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                title: String(text[separator.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines), coverURL: nil)
        }
        return WhitegramRadioTrack(artist: "", title: text, coverURL: nil)
    }
}

struct WhitegramRadioListeners: Decodable { let count: Int }
struct WhitegramRadioHeartbeat: Encodable { let playing: Bool }

final class WhitegramRadioHeartbeatPublisher {
    let userId: Int64
    private let client: WhitegramBackendClient
    private let now: () -> Date
    private let updated: (WhitegramBackendError?) -> Void
    private var desired: Bool?
    private var confirmed: Bool?
    private var confirmedAt: Date?
    private var retryAt: Date?
    private var task: WhitegramBackendTask?

    init(client: WhitegramBackendClient, now: @escaping () -> Date = Date.init, updated: @escaping (WhitegramBackendError?) -> Void) {
        self.userId = client.userId
        self.client = client
        self.now = now
        self.updated = updated
    }

    func update(playing: Bool) {
        precondition(Thread.isMainThread)
        if desired != playing { retryAt = nil }
        desired = playing
        publish()
    }

    private func publish() {
        guard task == nil, let playing = desired, retryAt.map({ $0 <= now() }) ?? true else { return }
        if playing == confirmed, let confirmedAt, now().timeIntervalSince(confirmedAt) < 25 { return }
        do {
            let body = try JSONEncoder().encode(WhitegramRadioHeartbeat(playing: playing))
            task = client.raw(path: "/v1/radio/heartbeat", method: "POST", body: body) { [self] result in
                task = nil
                switch result {
                case .success:
                    confirmed = playing
                    confirmedAt = now()
                    retryAt = nil
                    updated(nil)
                case let .failure(error):
                    let delay: TimeInterval
                    if case let .http(429, retryAfter) = error { delay = max(1, retryAfter ?? 60) }
                    else { delay = 30 }
                    retryAt = now().addingTimeInterval(delay)
                    updated(error)
                }
                // Serialize a stop/restart behind the request already accepted by URLSession.
                if desired != playing { retryAt = nil; publish() }
            }
        } catch { updated(.invalidRequest) }
    }
}
