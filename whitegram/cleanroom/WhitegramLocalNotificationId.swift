import Foundation

public struct WhitegramLocalNotificationId: Hashable {
    public let accountId: Int64
    public let peerId: Int64
    public let namespace: Int32
    public let messageId: Int32

    public init(accountId: Int64, peerId: Int64, namespace: Int32, messageId: Int32) {
        self.accountId = accountId
        self.peerId = peerId
        self.namespace = namespace
        self.messageId = messageId
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0] == "wg", parts[1] == "local",
              let accountId = Int64(parts[2]), let peerId = Int64(parts[3]),
              let namespace = Int32(parts[4]), let messageId = Int32(parts[5]) else { return nil }
        self.init(accountId: accountId, peerId: peerId, namespace: namespace, messageId: messageId)
        guard self.rawValue == rawValue else { return nil }
    }

    public var rawValue: String {
        return "wg_local_\(self.accountId)_\(self.peerId)_\(self.namespace)_\(self.messageId)"
    }

    public func threadIdentifier(threadId: Int64?) -> String {
        let peer = "wg_\(self.accountId)_\(self.peerId)"
        return threadId.map { peer + "_\($0)" } ?? peer
    }

    public func userInfo(threadId: Int64?) -> [String: Any] {
        var result: [String: Any] = [
            "accountId": String(self.accountId), "peerId": String(self.peerId),
            "messageId": String(self.messageId), "msg_id": String(self.messageId),
            "messageId.namespace": self.namespace, "messageId.id": self.messageId,
            "whitegramLocal": true
        ]
        if let threadId { result["threadId"] = threadId }
        return result
    }

    public func isRead(by maximum: Self) -> Bool {
        return self.accountId == maximum.accountId && self.peerId == maximum.peerId &&
            self.namespace == maximum.namespace && self.messageId <= maximum.messageId
    }
}

/// Main-queue ownership; tickets distinguish late callbacks from retries of the same message.
public final class WhitegramNotificationLedger {
    public struct Ticket {
        public let id: WhitegramLocalNotificationId
        fileprivate let serial: UInt64
    }

    private struct Scope: Hashable {
        let accountId: Int64
        let peerId: Int64
        let namespace: Int32
        init(_ id: WhitegramLocalNotificationId) {
            self.accountId = id.accountId
            self.peerId = id.peerId
            self.namespace = id.namespace
        }
    }

    private var serial: UInt64 = 0
    private var pending: [WhitegramLocalNotificationId: UInt64] = [:]
    private var delivered: Set<WhitegramLocalNotificationId> = []
    private var readWatermarks: [Scope: Int32] = [:]

    public init() {}

    public func reserve(_ id: WhitegramLocalNotificationId) -> Ticket? {
        guard !self.contains(id), !self.isRead(id), self.pending.count < 500 else { return nil }
        self.serial &+= 1
        self.pending[id] = self.serial
        return Ticket(id: id, serial: self.serial)
    }

    public func contains(_ id: WhitegramLocalNotificationId) -> Bool {
        return self.pending[id] != nil || self.delivered.contains(id)
    }

    public func isCurrent(_ ticket: Ticket) -> Bool {
        return self.pending[ticket.id] == ticket.serial
    }

    public func finish(_ ticket: Ticket, delivered: Bool) {
        guard self.isCurrent(ticket) else { return }
        self.pending.removeValue(forKey: ticket.id)
        if delivered {
            self.delivered.insert(ticket.id)
            if self.delivered.count > 500 { self.delivered = [ticket.id] }
        }
    }

    public func invalidatePending() -> [String] {
        // add(_:completionHandler:) acknowledges scheduling, not delivery of the 0.1-second trigger.
        let ids = Set(self.pending.keys).union(self.delivered).map(\.rawValue)
        self.pending.removeAll()
        return ids
    }

    @discardableResult
    public func recordRead(_ ids: [WhitegramLocalNotificationId]) -> [String] {
        for id in ids {
            let scope = Scope(id)
            self.readWatermarks[scope] = max(self.readWatermarks[scope] ?? Int32.min, id.messageId)
        }
        let cancelled = Set(self.pending.keys).union(self.delivered).filter(self.isRead).map(\.rawValue)
        self.pending = self.pending.filter { !self.isRead($0.key) }
        return cancelled
    }

    private func isRead(_ id: WhitegramLocalNotificationId) -> Bool {
        guard let maximum = self.readWatermarks[Scope(id)] else { return false }
        return id.messageId <= maximum
    }
}
