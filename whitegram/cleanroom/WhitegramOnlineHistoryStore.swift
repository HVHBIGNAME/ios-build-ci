import Foundation

public struct WhitegramOnlineHistoryEntry: Codable, Equatable {
    public let id: UUID
    public let peerId: Int64
    public let peerName: String
    public let peerUsername: String?
    public let isOnline: Bool
    public let isContact: Bool
    public let timestamp: Double

    init(peerId: Int64, peerName: String, peerUsername: String?, isOnline: Bool, timestamp: Double) {
        self.id = UUID()
        self.peerId = peerId
        self.peerName = String(peerName.prefix(256))
        self.peerUsername = peerUsername.map { String($0.prefix(64)) }
        self.isOnline = isOnline
        self.isContact = true
        self.timestamp = timestamp
    }

    var isValid: Bool {
        return peerId > 0 && isContact && timestamp.isFinite && timestamp >= 0
            && peerName.count <= 256 && (peerUsername?.count ?? 0) <= 64
            && peerName.utf8.count <= 2048 && (peerUsername?.utf8.count ?? 0) <= 256
    }
}

public struct WhitegramOnlineHistoryQuery {
    public var peerId: Int64?
    public var date: DateInterval?
    public var text = ""

    public init() {}

    public func apply(to entries: [WhitegramOnlineHistoryEntry]) -> [WhitegramOnlineHistoryEntry] {
        let text = self.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.reversed().filter { entry in
            if let peerId, entry.peerId != peerId { return false }
            if let date, entry.timestamp < date.start.timeIntervalSince1970 || entry.timestamp >= date.end.timeIntervalSince1970 { return false }
            return text.isEmpty || entry.peerName.localizedCaseInsensitiveContains(text)
                || (entry.peerUsername?.localizedCaseInsensitiveContains(text) ?? false)
                || String(entry.peerId) == text
        }
    }
}

private struct WhitegramOnlineHistoryArchive: Codable {
    let version: Int
    let accountId: Int64
    let entries: [WhitegramOnlineHistoryEntry]
}

private enum WhitegramOnlineHistoryError: LocalizedError {
    case invalidArchive

    var errorDescription: String? { return "Could not read the online-history archive. Existing data has not been replaced." }
}

public final class WhitegramOnlineHistoryStore: NSObject {
    public static let maximumEntries = 2000
    public static let pageSize = 50
    public static let updatedNotification = Notification.Name("WhitegramOnlineHistoryUpdated")
    private static let maximumBytes = 8 * 1024 * 1024
    private static let registryLock = NSLock()
    private static var stores: [Int64: WhitegramOnlineHistoryStore] = [:]

    public static func forAccount(_ accountId: Int64) -> WhitegramOnlineHistoryStore {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let store = stores[accountId] { return store }
        let store = WhitegramOnlineHistoryStore(accountId: accountId, defaults: .standard)
        stores[accountId] = store
        return store
    }

    private let accountId: Int64
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "Whitegram.OnlineHistory", qos: .utility)
    private var entries: [WhitegramOnlineHistoryEntry]?
    private var loadError: Error?
    var storageKey: String { return "WhitegramOnlineHistory.v1.\(self.accountId)" }

    init(accountId: Int64, defaults: UserDefaults) {
        self.accountId = accountId
        self.defaults = defaults
        super.init()
    }

    private func load() throws -> [WhitegramOnlineHistoryEntry] {
        if let loadError { throw loadError }
        if let entries { return entries }
        do {
            guard let object = defaults.object(forKey: storageKey) else { self.entries = []; return [] }
            guard let data = object as? Data, data.count <= Self.maximumBytes else { throw WhitegramOnlineHistoryError.invalidArchive }
            let archive = try JSONDecoder().decode(WhitegramOnlineHistoryArchive.self, from: data)
            guard archive.version == 1, archive.accountId == accountId, archive.entries.count <= Self.maximumEntries,
                  archive.entries.allSatisfy({ $0.isValid && $0.peerId != accountId }),
                  Set(archive.entries.map { $0.id }).count == archive.entries.count else { throw WhitegramOnlineHistoryError.invalidArchive }
            self.entries = archive.entries
            return archive.entries
        } catch {
            self.loadError = error
            throw error
        }
    }

    private func save(_ entries: [WhitegramOnlineHistoryEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(WhitegramOnlineHistoryArchive(version: 1, accountId: accountId, entries: entries))
        guard data.count <= Self.maximumBytes else { throw WhitegramOnlineHistoryError.invalidArchive }
        defaults.set(data, forKey: storageKey)
        self.entries = entries
        self.loadError = nil
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.updatedNotification, object: self) }
    }

    func append(_ incoming: [WhitegramOnlineHistoryEntry]) {
        guard !incoming.isEmpty else { return }
        queue.async {
            do {
                var entries = try self.load()
                var changed = false
                for entry in incoming where entry.isValid && entry.peerId != self.accountId {
                    if entries.last(where: { $0.peerId == entry.peerId })?.isOnline == entry.isOnline { continue }
                    entries.append(entry)
                    changed = true
                    if entries.count > Self.maximumEntries { entries.removeFirst(entries.count - Self.maximumEntries) }
                }
                if changed { try self.save(entries) }
            } catch {
                self.loadError = error
                NSLog("Whitegram: online-history capture failed (%@)", String(describing: type(of: error)))
                DispatchQueue.main.async { NotificationCenter.default.post(name: Self.updatedNotification, object: self) }
            }
        }
    }

    public func snapshot(completion: @escaping (Result<[WhitegramOnlineHistoryEntry], Error>) -> Void) {
        queue.async {
            let result = Result { try self.load() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    public func clear(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async {
            let result = Result { try self.save([]) }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
