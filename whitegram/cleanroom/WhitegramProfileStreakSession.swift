import Foundation
#if canImport(TelegramCore)
import TelegramCore
#endif

struct WhitegramProfileStreakThrottle {
    private struct Entry { let messageId: Int32; let date: Date }
    private var accepted: [String: Entry] = [:]

    mutating func accept(_ event: WhitegramBackendMessageEvent, accountId: Int64, enabled: Bool, now: Date) -> Bool {
        guard enabled, event.accountId == accountId, accountId > 0, event.peerId > 0, event.peerId != accountId,
              event.messageId > 0, event.timestamp > 0 else { return false }
        let key = "\(event.peerId):\(event.direction.rawValue)"
        if let previous = accepted[key], previous.messageId == event.messageId || now.timeIntervalSince(previous.date) < 60 { return false }
        if accepted.count >= 10000, let oldest = accepted.min(by: { $0.value.date < $1.value.date })?.key { accepted.removeValue(forKey: oldest) }
        accepted[key] = Entry(messageId: event.messageId, date: now)
        return true
    }
}

final class WhitegramProfileStreakSession {
    static let updated = Notification.Name("WhitegramBackendStreakUpdated")
    let service: WhitegramProfileStreakService
    private let enabled: () -> Bool
    private let now: () -> Date
    private var throttle = WhitegramProfileStreakThrottle()
    private var pending: [WhitegramBackendMessageEvent] = []
    private var task: WhitegramBackendTask?
    private var generation = 0
    private var synchronizedSession: WhitegramBackendSession?
    private(set) var synchronizedEnabled: Bool?
    private(set) var lastError: WhitegramBackendError?
    private var retryAt: Date?
    var pendingCount: Int { return pending.count }

    init(client: WhitegramBackendClient, enabled: @escaping () -> Bool, now: @escaping () -> Date = Date.init) {
        service = WhitegramProfileStreakService(client: client)
        self.enabled = enabled
        self.now = now
    }
    deinit { task?.cancel() }

    func enqueue(_ event: WhitegramBackendMessageEvent) {
        precondition(Thread.isMainThread)
        guard pending.count < 256 else { lastError = .queueFull; notify(); return }
        guard throttle.accept(event, accountId: service.client.userId, enabled: enabled(), now: now()) else { return }
        pending.append(event)
        process()
    }

    func sessionDidChange() {
        precondition(Thread.isMainThread)
        generation += 1
        task?.cancel()
        task = nil
        synchronizedSession = nil
        synchronizedEnabled = nil
        retryAt = nil
        lastError = nil
        process()
    }

    func settingsDidChange() {
        precondition(Thread.isMainThread)
        if !enabled() {
            pending.removeAll()
            throttle = WhitegramProfileStreakThrottle()
        }
        retryAt = nil
        process()
    }

    func process() {
        precondition(Thread.isMainThread)
        guard task == nil, retryAt.map({ $0 <= now() }) ?? true else { return }
        let isEnabled = enabled()
        let session: WhitegramBackendSession
        do {
            guard let value = try service.client.sessions.load(userId: service.client.userId) else { throw WhitegramBackendError.missingSession }
            try value.validate(userId: service.client.userId, now: now())
            session = value
        } catch {
            lastError = isEnabled ? (error as? WhitegramBackendError ?? .invalidResponse) : nil
            notify()
            return
        }
        let generation = self.generation
        if synchronizedSession != session || synchronizedEnabled != isEnabled {
            task = service.setEnabled(isEnabled) { [weak self] result in
                guard let self, generation == self.generation else { return }
                task = nil
                switch result {
                case .success:
                    synchronizedSession = session
                    synchronizedEnabled = isEnabled
                    lastError = nil
                    retryAt = nil
                    notify()
                    process()
                case let .failure(error): failed(error)
                }
            }
        } else if isEnabled, let event = pending.first {
            task = service.report(event) { [weak self] result in
                guard let self, generation == self.generation else { return }
                task = nil
                switch result {
                case .success:
                    pending.removeAll { $0 == event }
                    lastError = nil
                    retryAt = nil
                    notify()
                    process()
                case let .failure(error): failed(error)
                }
            }
        } else { notify() }
    }

    private func failed(_ error: WhitegramBackendError) {
        lastError = error
        let delay: TimeInterval
        if case let .http(429, retryAfter) = error { delay = max(1, retryAfter ?? 60) }
        else { delay = 60 }
        retryAt = now().addingTimeInterval(delay)
        notify()
        // Disable may have happened while this request was in flight.
        if !enabled(), synchronizedEnabled != false { synchronizedEnabled = nil }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.updated, object: self, userInfo: ["userId": service.client.userId])
    }
}
