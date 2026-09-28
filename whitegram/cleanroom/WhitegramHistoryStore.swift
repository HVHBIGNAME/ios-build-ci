import Foundation
import Postbox

public enum WhitegramHistoryEvent: String, Codable, CaseIterable {
    case received
    case deleted
    case edited
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
}

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
    private static let registryLock = NSLock()
    private static var stores: [String: WhitegramHistoryStore] = [:]
    private static let maximumEntries = 2000
    private static let maximumTextBytes = 8192

    public static func forAccount(mediaBoxPath: String, accountPeerId: PeerId) -> WhitegramHistoryStore {
        let directory = URL(fileURLWithPath: mediaBoxPath).deletingLastPathComponent()
        registryLock.lock()
        defer { registryLock.unlock() }
        if let store = stores[directory.path] { return store }
        let store = WhitegramHistoryStore(directory: directory, accountId: String(accountPeerId.toInt64()))
        stores[directory.path] = store
        return store
    }

    public static func capture(_ message: EngineRawMessage, event: WhitegramHistoryEvent, accountPeerId: PeerId, mediaBoxPath: String) {
        guard message.id.namespace == Namespaces.Message.Cloud else { return }
        let flags = WhitegramPreferences.values()
        let enabled: Bool
        switch event {
        case .received: enabled = flags["saveChatHistory"] as? Bool == true
        case .deleted: enabled = flags["showDeletedMessages"] as? Bool == true || flags["saveDeletedMessagesToBackup"] as? Bool == true || flags["saveChatHistory"] as? Bool == true
        case .edited: enabled = flags["showEditedOriginalText"] as? Bool == true || flags["saveChatHistory"] as? Bool == true
        }
        guard enabled else { return }
        let outgoing = !message.flags.contains(.Incoming)
        let bot = (message.author as? TelegramUser)?.botInfo != nil
        if event == .deleted && ((outgoing && flags["hideMyDeletedMessages"] as? Bool == true) || (bot && flags["hideBotDeletedMessages"] as? Bool == true)) { return }
        if event == .edited && ((outgoing && flags["hideMyEditedMessages"] as? Bool == true) || (bot && flags["hideBotEditedMessages"] as? Bool == true)) { return }
        let peerId = String(message.id.peerId.toInt64())
        let entry = WhitegramHistoryEntry(
            key: "\(peerId):\(message.id.namespace):\(message.id.id):\(event.rawValue):\(message.stableVersion)",
            accountId: String(accountPeerId.toInt64()), peerId: peerId, namespace: message.id.namespace,
            messageId: message.id.id, revision: message.stableVersion, messageDate: message.timestamp,
            capturedAt: Date().timeIntervalSince1970, event: event,
            text: String(decoding: message.text.utf8.prefix(maximumTextBytes), as: UTF8.self),
            authorId: message.author.map { String($0.id.toInt64()) }, outgoing: outgoing, mediaCount: message.media.count
        )
        forAccount(mediaBoxPath: mediaBoxPath, accountPeerId: accountPeerId).append(entry)
    }

    private let queue = DispatchQueue(label: "Whitegram.History", qos: .utility)
    private let directory: URL
    private let file: URL
    private let accountId: String
    private var loaded = false
    private var entries: [String: WhitegramHistoryEntry] = [:]
    private var pendingWrite = false
    private var loadError: Error?
    private var writeError: Error?

    private init(directory: URL, accountId: String) {
        self.directory = directory
        self.file = directory.appendingPathComponent("whitegram-history-v1.json")
        self.accountId = accountId
        super.init()
    }

    private func load() throws {
        if let loadError { throw loadError }
        guard !self.loaded else { return }
        self.loaded = true
        guard FileManager.default.fileExists(atPath: self.file.path) else { return }
        do {
            let input = try FileHandle(forReadingFrom: self.file)
            defer { input.closeFile() }
            let archive = try self.decode(input.readData(ofLength: Self.maximumArchiveBytes + 1))
            self.entries = Dictionary(archive.entries.map { ($0.key, $0) }, uniquingKeysWith: { old, new in old.capturedAt > new.capturedAt ? old : new })
        } catch {
            self.loadError = error
            throw error
        }
    }

    private func decode(_ data: Data) throws -> WhitegramHistoryArchive {
        guard data.count <= Self.maximumArchiveBytes else { throw WhitegramHistoryError.invalidArchive }
        let archive = try JSONDecoder().decode(WhitegramHistoryArchive.self, from: data)
        guard archive.version == 1, archive.entries.count <= Self.maximumEntries else { throw WhitegramHistoryError.invalidArchive }
        guard archive.accountId == self.accountId else { throw WhitegramHistoryError.differentAccount }
        for item in archive.entries {
            let expectedKey = "\(item.peerId):\(item.namespace):\(item.messageId):\(item.event.rawValue):\(item.revision)"
            guard item.accountId == self.accountId, Int64(item.peerId) != nil, item.namespace == Namespaces.Message.Cloud,
                  item.messageId > 0, item.text.utf8.count <= Self.maximumTextBytes + 3,
                  item.key == expectedKey, item.mediaCount >= 0, item.mediaCount <= 1000,
                  item.capturedAt.isFinite, item.capturedAt >= 0,
                  item.capturedAt <= Date().timeIntervalSince1970 + 86400 else { throw WhitegramHistoryError.invalidArchive }
        }
        return archive
    }

    private func ordered() -> [WhitegramHistoryEntry] {
        return self.entries.values.sorted { lhs, rhs in
            return lhs.capturedAt == rhs.capturedAt ? lhs.key < rhs.key : lhs.capturedAt > rhs.capturedAt
        }
    }

    private func persist() throws {
        guard FileManager.default.fileExists(atPath: self.directory.path) else { throw WhitegramHistoryError.accountRemoved }
        var sorted = Array(self.ordered().prefix(Self.maximumEntries))
        var data = try JSONEncoder().encode(WhitegramHistoryArchive(version: 1, accountId: self.accountId, entries: sorted))
        while data.count > Self.maximumArchiveBytes && !sorted.isEmpty {
            sorted.removeLast(min(100, sorted.count))
            data = try JSONEncoder().encode(WhitegramHistoryArchive(version: 1, accountId: self.accountId, entries: sorted))
        }
        try data.write(to: self.file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        self.entries = Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0) })
        self.writeError = nil
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.updatedNotification, object: self) }
    }

    private func append(_ entry: WhitegramHistoryEntry) {
        self.queue.async {
            do {
                try self.load()
                if self.entries[entry.key] != nil { return }
                self.entries[entry.key] = entry
                if self.entries.count > Self.maximumEntries {
                    self.entries = Dictionary(uniqueKeysWithValues: self.ordered().prefix(Self.maximumEntries).map { ($0.key, $0) })
                }
                guard !self.pendingWrite else { return }
                self.pendingWrite = true
                self.queue.asyncAfter(deadline: .now() + 0.25) {
                    self.pendingWrite = false
                    do { try self.persist() }
                    catch { self.writeError = error; NSLog("Whitegram: history write failed") }
                }
            } catch { NSLog("Whitegram: history capture unavailable") }
        }
    }

    public func snapshot(completion: @escaping (Result<[WhitegramHistoryEntry], Error>) -> Void) {
        self.queue.async {
            let result = Result { try self.load(); if self.writeError != nil { try self.persist() }; return self.ordered() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    public func clear(event: WhitegramHistoryEvent? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        self.queue.async {
            let result = Result {
                if event != nil { try self.load() }
                let previous = self.entries
                self.entries = self.entries.filter { _, entry in event != nil && entry.event != event }
                do { try self.persist(); self.loadError = nil; self.loaded = true }
                catch { self.entries = previous; throw error }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    public func export(completion: @escaping (Result<Data, Error>) -> Void) {
        self.queue.async {
            let result = Result { try self.load(); try self.persist(); return try JSONEncoder().encode(WhitegramHistoryArchive(version: 1, accountId: self.accountId, entries: self.ordered())) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    public func importArchive(_ data: Data, completion: @escaping (Result<Int, Error>) -> Void) {
        self.queue.async {
            let result = Result {
                let archive = try self.decode(data)
                try self.load()
                let previous = self.entries
                for item in archive.entries {
                    if let old = self.entries[item.key], old.capturedAt >= item.capturedAt { continue }
                    self.entries[item.key] = item
                }
                do { try self.persist() }
                catch { self.entries = previous; throw error }
                return archive.entries.count
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
