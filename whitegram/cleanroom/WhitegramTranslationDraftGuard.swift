import Foundation

/// Main-thread state for a translate/review/send cycle. A result never authorizes a send.
public final class WhitegramTranslationDraftGuard<Snapshot: Equatable> {
    private var request: (id: UUID, snapshot: Snapshot)?
    private var reviewed: Snapshot?

    public init() {}

    public var isPending: Bool { return self.request != nil }

    @discardableResult
    public func observe(_ snapshot: Snapshot) -> Bool {
        let cancelled = self.request.map { $0.snapshot != snapshot } ?? false
        if cancelled { self.request = nil }
        if self.reviewed != snapshot { self.reviewed = nil }
        return cancelled
    }

    public func begin(_ snapshot: Snapshot) -> UUID {
        let id = UUID()
        self.request = (id, snapshot)
        self.reviewed = nil
        return id
    }

    public func isCurrent(_ id: UUID, snapshot: Snapshot) -> Bool {
        return self.request?.id == id && self.request?.snapshot == snapshot
    }

    /// Call before installing a result. Late, cancelled and replaced requests fail closed.
    public func finish(_ id: UUID, snapshot: Snapshot) -> Bool {
        guard self.isCurrent(id, snapshot: snapshot) else { return false }
        self.request = nil
        return true
    }

    /// Only the exact draft installed for review can pass the next explicit send action.
    public func markForReview(_ snapshot: Snapshot) {
        self.request = nil
        self.reviewed = snapshot
    }

    public func isReviewed(_ snapshot: Snapshot) -> Bool {
        return self.reviewed == snapshot
    }

    public func cancel() {
        self.request = nil
        self.reviewed = nil
    }
}
