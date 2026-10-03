import Foundation

// Serializes cancellation against the AccountManager transaction that publishes a verified login.
final class WhitegramAccountImportState {
    private let lock = NSLock()
    private var recordId: Int64?
    private var cancelled = false
    private var committed = false

    func allocate(_ body: () -> Int64) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, recordId == nil else { return nil }
        let id = body()
        recordId = id
        return id
    }

    func commit(_ body: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !committed, recordId != nil else { return false }
        guard body() else { return false }
        committed = true
        return true
    }

    func cancel() -> Int64? {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        guard !committed else { return nil }
        let id = recordId
        recordId = nil
        return id
    }
}
