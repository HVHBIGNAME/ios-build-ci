import Foundation

public enum WhitegramAccountUnavailableReason: Int32, Codable {
    case unknown = 0, deleted = 1, banned = 2, sessionRevoked = 3, frozen = 4

    public static func rpcError(_ value: String) -> WhitegramAccountUnavailableReason? {
        switch value {
        case "USER_DEACTIVATED": return .deleted
        case "USER_DEACTIVATED_BAN": return .banned
        case "SESSION_REVOKED", "SESSION_EXPIRED", "AUTH_KEY_UNREGISTERED", "AUTH_KEY_INVALID", "AUTH_KEY_DUPLICATED": return .sessionRevoked
        case "FROZEN_METHOD_INVALID": return .frozen
        default: return nil
        }
    }
}

public struct WhitegramFrozenAccount: Codable, Equatable {
    public let accountId: Int64
    public let peerId: Int64?
    public let reason: WhitegramAccountUnavailableReason
    public let frozenAt: Int32
}

public final class WhitegramAccountFrozenStore {
    public static let shared = WhitegramAccountFrozenStore(defaults: .standard)
    public static let didChange = Notification.Name("wg_frozenAccountsDidChange")
    private static let key = "wg_frozenAccounts_v1"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var lastError: WhitegramSessionError?

    public init(defaults: UserDefaults) { self.defaults = defaults }

    private func load() throws -> [Int64: WhitegramFrozenAccount] {
        guard let stored = defaults.object(forKey: Self.key) else { return [:] }
        guard let data = stored as? Data else { throw WhitegramSessionError.invalidFormat }
        guard data.count <= 1024 * 1024 else { throw WhitegramSessionError.tooLarge }
        let entries: [Int64: WhitegramFrozenAccount]
        do { entries = try JSONDecoder().decode([Int64: WhitegramFrozenAccount].self, from: data) }
        catch { throw WhitegramSessionError.invalidFormat }
        guard entries.count <= 1000, entries.allSatisfy({ $0.key == $0.value.accountId }) else { throw WhitegramSessionError.invalidFormat }
        return entries
    }

    public func all() throws -> [Int64: WhitegramFrozenAccount] {
        lock.lock(); defer { lock.unlock() }
        return try load()
    }

    public func entry(accountId: Int64) -> WhitegramFrozenAccount? {
        lock.lock(); defer { lock.unlock() }
        do { let result = try load()[accountId]; lastError = nil; return result }
        catch { lastError = error as? WhitegramSessionError ?? .invalidFormat; return nil }
    }

    public func error() -> WhitegramSessionError? {
        lock.lock(); defer { lock.unlock() }
        return lastError
    }

    @discardableResult public func markFrozen(accountId: Int64, peerId: Int64?, reason: WhitegramAccountUnavailableReason, now: Date = Date()) -> Bool {
        return update { entries in
            if let previous = entries[accountId], previous.reason != .unknown { return }
            let seconds = now.timeIntervalSince1970
            let timestamp = seconds.isFinite ? Int32(max(0, min(Double(Int32.max), seconds))) : 0
            entries[accountId] = WhitegramFrozenAccount(accountId: accountId, peerId: peerId, reason: reason, frozenAt: timestamp)
        }
    }

    @discardableResult public func clear(accountId: Int64) -> Bool { return update { $0.removeValue(forKey: accountId) } }

    private func update(_ f: (inout [Int64: WhitegramFrozenAccount]) -> Void) -> Bool {
        lock.lock()
        do {
            var entries = try load()
            let before = entries
            f(&entries)
            guard before != entries else { lastError = nil; lock.unlock(); return true }
            guard entries.count <= 1000 else { throw WhitegramSessionError.tooLarge }
            let data = try JSONEncoder().encode(entries)
            guard data.count <= 1024 * 1024 else { throw WhitegramSessionError.tooLarge }
            defaults.set(data, forKey: Self.key)
            guard defaults.data(forKey: Self.key) == data else { throw WhitegramSessionError.storageVerification }
            lastError = nil
            lock.unlock()
            NotificationCenter.default.post(name: Self.didChange, object: self)
            return true
        } catch {
            lastError = error as? WhitegramSessionError ?? .invalidFormat
            lock.unlock()
            NotificationCenter.default.post(name: Self.didChange, object: self)
            return false
        }
    }
}
