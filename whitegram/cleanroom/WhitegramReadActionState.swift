import Foundation

/// A receipt authorization names one account and one exact history snapshot.
/// It is carried by the action's signal, never put in preferences or a global pending flag.
struct WhitegramReadActionScope: Equatable {
    let accountId: Int64
    let peerId: Int64
    let threadId: Int64?
    let namespace: Int32
    let messageId: Int32
    let timestamp: Int32
}

final class WhitegramReadActionPermit {
    private let scope: WhitegramReadActionScope
    private let lock = NSLock()
    private var consumed = false

    init(scope: WhitegramReadActionScope) { self.scope = scope }

    func consume(for scope: WhitegramReadActionScope) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.scope == scope, !consumed else { return false }
        consumed = true
        return true
    }
}
