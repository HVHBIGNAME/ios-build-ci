import Foundation

private struct WhitegramHistoryArchive: Codable {
    let version: Int
    let accountId: String
    let entries: [WhitegramHistoryEntry]
}

private enum WhitegramHistoryError: LocalizedError {
    case invalidArchive
    case differentAccount
    case accountRemoved

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "Invalid or oversized Whitegram history archive."
        case .differentAccount: return "This archive belongs to a different Telegram account."
        case .accountRemoved: return "The account's local directory is no longer available."
        }
    }
}

public final class WhitegramHistoryStore: NSObject {
    public static let updatedNotification = Notification.Name("WhitegramHistoryUpdated")
    public static let maximumArchiveBytes = 8 * 1024 * 1024
    public static let maximumEntries = 2000
    // Covers ordinary Telegram text/captions without the previous 8 KiB loss.
    // Full native retained messages and their edit attributes are not truncated.
    static let maximumTextBytes = 65536
    static let maximumMediaItems = 32
    static let maximumNameBytes = 512

    private struct AccountKey: Hashable {
        let directory: String
        let accountId: Int64
    }

    private static let registryLock = NSLock()
    private static var stores: [AccountKey: WhitegramHistoryStore] = [:]

    static func accountStore(directory: URL, accountId: Int64, cloudNamespace: Int32) -> WhitegramHistoryStore {
        let directory = directory.standardizedFileURL
        let key = AccountKey(directory: directory.path, accountId: accountId)
        self.registryLock.lock()
        defer { self.registryLock.unlock() }
        if let store = self.stores[key] { return store }
        let store = WhitegramHistoryStore(directory: directory, accountId: accountId, cloudNamespace: cloudNamespace)
        self.stores[key] = store
        return store
    }

    private let queue = DispatchQueue(label: "Whitegram.History", qos: .utility)
    private let directory: URL
    private let file: URL
    private let legacyFile: URL
    private let accountId: String
    private let cloudNamespace: Int32
    private var loaded = false
    private var entries: [String: WhitegramHistoryEntry] = [:]
    private var pendingWrite = false
    private var loadError: Error?
    private var writeError: Error?

    init(directory: URL, accountId: Int64, cloudNamespace: Int32) {
        self.directory = directory
        self.file = directory.appendingPathComponent("whitegram-history-\(accountId)-v1.json")
        self.legacyFile = directory.appendingPathComponent("whitegram-history-v1.json")
        self.accountId = String(accountId)
        self.cloudNamespace = cloudNamespace
        super.init()
    }

    private func load() throws {
        if let loadError { throw loadError }
        guard !self.loaded else { return }
        self.loaded = true
        let source: URL
        if FileManager.default.fileExists(atPath: self.file.path) {
            source = self.file
        } else if FileManager.default.fileExists(atPath: self.legacyFile.path) {
            source = self.legacyFile
        } else {
            return
        }
        let archive: WhitegramHistoryArchive
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { input.closeFile() }
            archive = try self.decode(input.readData(ofLength: Self.maximumArchiveBytes + 1))
        } catch WhitegramHistoryError.differentAccount where source == self.legacyFile {
            // A reused account directory can contain another account's legacy file. Leave it for its owner.
            return
        } catch {
            self.loadError = error
            throw error
        }
        if source == self.legacyFile {
            do { try FileManager.default.moveItem(at: source, to: self.file) }
            catch { self.loaded = false; throw error }
        }
        self.entries = Dictionary(archive.entries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func validate(_ entry: WhitegramHistoryEntry) throws {
        guard entry.accountId == self.accountId else { throw WhitegramHistoryError.differentAccount }
        let expectedKey = "\(entry.peerId):\(entry.namespace):\(entry.messageId):\(entry.event.rawValue):\(entry.revision)"
        guard whitegramHistoryValidPeer(entry.peerId),
              entry.namespace == self.cloudNamespace, entry.messageId > 0, entry.key == expectedKey,
              entry.text.utf8.count <= Self.maximumTextBytes + 3,
              entry.mediaCount >= 0, entry.mediaCount <= 1000,
              entry.capturedAt.isFinite, entry.capturedAt >= 0,
              entry.capturedAt <= Date().timeIntervalSince1970 + 86400,
              (entry.peerTitle?.utf8.count ?? 0) <= Self.maximumNameBytes,
              (entry.authorName?.utf8.count ?? 0) <= Self.maximumNameBytes else {
            throw WhitegramHistoryError.invalidArchive
        }
        if let authorId = entry.authorId, !whitegramHistoryValidPeer(authorId) {
            throw WhitegramHistoryError.invalidArchive
        }
        for value in [entry.threadId, entry.groupingKey].compactMap({ $0 }) {
            if Int64(value).map({ String($0) }) != value { throw WhitegramHistoryError.invalidArchive }
        }
        if let media = entry.media {
            guard media.count <= min(entry.mediaCount, Self.maximumMediaItems) else { throw WhitegramHistoryError.invalidArchive }
            for item in media {
                guard (item.mediaId?.utf8.count ?? 0) <= 64,
                      (item.fileName?.utf8.count ?? 0) <= Self.maximumNameBytes,
                      (item.mimeType?.utf8.count ?? 0) <= 256,
                      item.size.map({ $0 >= 0 }) ?? true,
                      item.width.map({ $0 > 0 }) ?? true,
                      item.height.map({ $0 > 0 }) ?? true,
                      item.duration.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                    throw WhitegramHistoryError.invalidArchive
                }
            }
        }
    }

    private func decode(_ data: Data) throws -> WhitegramHistoryArchive {
        guard data.count <= Self.maximumArchiveBytes else { throw WhitegramHistoryError.invalidArchive }
        let archive = try JSONDecoder().decode(WhitegramHistoryArchive.self, from: data)
        guard archive.version == 1, archive.entries.count <= Self.maximumEntries else { throw WhitegramHistoryError.invalidArchive }
        guard archive.accountId == self.accountId else { throw WhitegramHistoryError.differentAccount }
        for entry in archive.entries { try self.validate(entry) }
        return archive
    }

    private func ordered() -> [WhitegramHistoryEntry] {
        return WhitegramHistoryQuery(order: .captureTime).apply(to: Array(self.entries.values))
    }

    private func encode(_ entries: [WhitegramHistoryEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(WhitegramHistoryArchive(version: 1, accountId: self.accountId, entries: entries))
    }

    private func persist() throws {
        guard FileManager.default.fileExists(atPath: self.directory.path) else { throw WhitegramHistoryError.accountRemoved }
        var sorted = Array(self.ordered().prefix(Self.maximumEntries))
        var data = try self.encode(sorted)
        while data.count > Self.maximumArchiveBytes && !sorted.isEmpty {
            sorted.removeLast(min(100, sorted.count))
            data = try self.encode(sorted)
        }
        try data.write(to: self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        self.entries = Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0) })
        self.pendingWrite = false
        self.writeError = nil
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.updatedNotification, object: self) }
    }

    func append(_ entry: WhitegramHistoryEntry) {
        self.queue.async {
            do {
                try self.load()
                try self.validate(entry)
                if self.entries[entry.key] != nil { return }
                self.entries[entry.key] = entry
                if self.entries.count > Self.maximumEntries {
                    self.entries = Dictionary(uniqueKeysWithValues: self.ordered().prefix(Self.maximumEntries).map { ($0.key, $0) })
                }
                guard !self.pendingWrite else { return }
                self.pendingWrite = true
                self.queue.asyncAfter(deadline: .now() + 0.25) {
                    guard self.pendingWrite else { return }
                    self.pendingWrite = false
                    do { try self.persist() }
                    catch { self.writeError = error; NSLog("Whitegram: history write failed") }
                }
            } catch { NSLog("Whitegram: history capture unavailable") }
        }
    }

    public func snapshot(matching query: WhitegramHistoryQuery = WhitegramHistoryQuery(), completion: @escaping (Result<[WhitegramHistoryEntry], Error>) -> Void) {
        self.queue.async {
            let result = Result {
                try self.load()
                if self.pendingWrite || self.writeError != nil { try self.persist() }
                return query.apply(to: Array(self.entries.values))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    public func clear(event: WhitegramHistoryEvent? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        self.clear(matching: WhitegramHistoryQuery(event: event), completion: completion)
    }

    public func clear(matching query: WhitegramHistoryQuery, completion: @escaping (Result<Void, Error>) -> Void) {
        self.queue.async {
            let result = Result {
                // Loading also verifies ownership. Even a full clear must not overwrite another account's file.
                try self.load()
                let previous = self.entries
                self.entries = self.entries.filter { !query.matches($0.value) }
                do { try self.persist() }
                catch { self.entries = previous; throw error }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    public func export(matching query: WhitegramHistoryQuery = WhitegramHistoryQuery(), completion: @escaping (Result<Data, Error>) -> Void) {
        self.queue.async {
            let result = Result {
                try self.load()
                if self.pendingWrite || self.writeError != nil { try self.persist() }
                return try self.encode(query.apply(to: Array(self.entries.values)))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    public func importArchive(_ data: Data, completion: @escaping (Result<Int, Error>) -> Void) {
        self.queue.async {
            let result = Result {
                let archive = try self.decode(data)
                try self.load()
                let previous = self.entries
                var inserted = Set<String>()
                for entry in archive.entries where self.entries[entry.key] == nil {
                    self.entries[entry.key] = entry
                    inserted.insert(entry.key)
                }
                // First observation wins, including its timestamp; replay cannot rewrite local versions.
                if !inserted.isEmpty {
                    do { try self.persist() }
                    catch { self.entries = previous; throw error }
                }
                return inserted.intersection(self.entries.keys).count
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// The caller must obtain confirmation naming this account before using this
    /// entry point. Modern archives always use importArchive and validate ownership.
    public func importOriginalBackupForThisAccount(_ data: Data, completion: @escaping (Result<Int, Error>) -> Void) {
        self.queue.async {
            do {
                guard data.count <= Self.maximumArchiveBytes else { throw WhitegramHistoryBackupError.invalidLegacyBackup }
                let legacy = try JSONDecoder().decode([WhitegramHistoryLegacyMessage].self, from: data)
                guard legacy.count <= Self.maximumEntries else { throw WhitegramHistoryBackupError.invalidLegacyBackup }
                let timestamp = Date().timeIntervalSince1970
                let entries = try legacy.map { try $0.entry(accountId: self.accountId, capturedAt: timestamp) }
                let encoded = try self.encode(entries)
                // Use the same all-or-nothing validator, ownership checks and merge.
                self.importArchive(encoded, completion: completion)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
