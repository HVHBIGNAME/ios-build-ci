import Foundation
#if canImport(TelegramCore)
import TelegramCore
#endif

/// Main-thread, screen-owned registration data. The original persistent cache and
/// known-user prefilter are not reproduced; this uses the authenticated profile service.
public final class WhitegramPeerMetadataCardAdapter {
    private struct Input: Equatable {
        let userId: Int64
        let telegramDate: WhitegramPeerMetadataDate?
    }

    public var updated: (() -> Void)?
    private let client: WhitegramBackendClient
    private var service: WhitegramProfileService
    private let now: () -> Date
    private let automaticallyRefresh: Bool
    private var input: Input?
    private var suppliedDate: WhitegramPeerMetadataDate?
    private var session: WhitegramBackendSession?
    private var deadline: Date?
    private var task: WhitegramBackendTask?
    private var generation = 0
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    public convenience init(accountUserId: Int64) {
        self.init(client: WhitegramBackendClient(userId: accountUserId))
    }

    init(client: WhitegramBackendClient, now: (() -> Date)? = nil, automaticallyRefresh: Bool = true) {
        precondition(Thread.isMainThread)
        self.client = client
        let clock = now ?? client.now
        self.now = clock
        self.service = WhitegramProfileService(client: client, now: clock)
        self.automaticallyRefresh = automaticallyRefresh
        for name in [WhitegramBackendClient.sessionUpdated, WhitegramBackendAccessStore.updated, WhitegramProfileService.updated] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self else { return }
                let key = name == WhitegramProfileService.updated ? "accountId" : "userId"
                guard notification.userInfo?[key] as? Int64 == client.userId else { return }
                self.invalidate()
            })
        }
    }

    deinit {
        timer?.invalidate()
        task?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    public var date: WhitegramPeerMetadataDate? {
        precondition(Thread.isMainThread)
        guard let input else { return nil }
        if let telegramDate = input.telegramDate { return telegramDate }
        guard snapshotIsCurrent else { return nil }
        return suppliedDate
    }

    /// The caller lays out after update. Asynchronous changes call updated.
    public func update(userId: Int64?, telegramMonth: String?, enabled: Bool) {
        precondition(Thread.isMainThread)
        let next: Input?
        if enabled, let userId, userId > 0 {
            next = Input(userId: userId, telegramDate: WhitegramPeerMetadataDate.telegramMonth(telegramMonth))
        } else {
            next = nil
        }
        if input != next {
            reset()
            input = next
        }
        guard let input, input.telegramDate == nil else { return }
        if automaticallyRefresh && timer == nil {
            // Access grants can expire without a notification. Revalidate displayed
            // service data while this screen is alive; HTTP retries remain bounded.
            timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.refreshIfNeeded() }
        }
        refreshIfNeeded()
    }

    public func cancel() {
        precondition(Thread.isMainThread)
        reset()
        input = nil
    }

    private func currentSession() throws -> WhitegramBackendSession {
        guard let session = try client.sessions.load(userId: client.userId) else { throw WhitegramBackendError.missingSession }
        try session.validate(userId: client.userId, now: now())
        try client.access.require(userId: client.userId, path: WhitegramProfileResource.registration.path, now: now())
        return session
    }

    private var snapshotIsCurrent: Bool {
        guard let session, let deadline, deadline > now(),
              let current = try? currentSession() else { return false }
        return current == session
    }

    private func reset() {
        generation += 1
        task?.cancel()
        task = nil
        timer?.invalidate()
        timer = nil
        suppliedDate = nil
        session = nil
        deadline = nil
    }

    private func invalidate() {
        precondition(Thread.isMainThread)
        let previous = input
        reset()
        // Other profile-service instances publish mutations. Do not reuse a cache
        // which predates that notification or let its old request repopulate it.
        service = WhitegramProfileService(client: client, now: now)
        input = nil
        if let previous {
            if let telegramDate = previous.telegramDate {
                input = Input(userId: previous.userId, telegramDate: telegramDate)
            } else {
                update(userId: previous.userId, telegramMonth: nil, enabled: true)
            }
        }
        updated?()
    }

    func refreshIfNeeded() {
        precondition(Thread.isMainThread)
        guard let input, input.telegramDate == nil else { return }
        if session != nil && !snapshotIsCurrent {
            let hadDate = suppliedDate != nil
            suppliedDate = nil
            session = nil
            deadline = nil
            if hadDate { updated?() }
        }
        guard task == nil, deadline.map({ $0 <= now() }) ?? true else { return }
        let startingSession: WhitegramBackendSession
        do { startingSession = try currentSession() }
        catch { deadline = now().addingTimeInterval(60); return }
        let generation = self.generation
        task = service.registrationDate(userId: input.userId, force: true) { [weak self] result in
            guard let self, self.generation == generation, self.input == input else { return }
            self.task = nil
            self.suppliedDate = nil
            switch result {
            case let .success(value):
                guard (try? self.currentSession()) == startingSession else {
                    self.deadline = self.now().addingTimeInterval(60)
                    self.updated?()
                    return
                }
                self.suppliedDate = WhitegramPeerMetadataDate(year: value.year, month: value.month, day: value.day, exact: value.exact)
                self.session = startingSession
                self.deadline = self.now().addingTimeInterval(WhitegramProfileResource.registration.cacheLifetime)
            case let .failure(error):
                let delay: TimeInterval
                if case let .http(429, retryAfter) = error { delay = max(60, retryAfter ?? 60) }
                else { delay = 60 }
                self.deadline = self.now().addingTimeInterval(delay)
            }
            self.updated?()
        }
    }
}
