import Foundation
import UIKit
import TelegramCore

final class WhitegramBackendActivityRuntime {
    static let shared = WhitegramBackendActivityRuntime()
    private var sessions: [Int64: WhitegramProfileStreakSession] = [:]
    private var accessTasks: [Int64: WhitegramBackendTask] = [:]
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    private init() {
        observers.append(whitegramServiceObserve(WhitegramBackendMessageEvent.notification) { [weak self] notification in
            guard let event = notification.object as? WhitegramBackendMessageEvent else { return }
            self?.streaks(userId: event.accountId).enqueue(event)
        })
        observers.append(whitegramServiceObserve(WhitegramPreferences.updatedNotification) { [weak self] _ in
            self?.sessions.values.forEach { $0.settingsDidChange() }
        })
        for name in [WhitegramBackendClient.sessionUpdated, WhitegramBackendSessionMigration.completed] {
            observers.append(whitegramServiceObserve(name) { [weak self] notification in
                guard let userId = notification.userInfo?["userId"] as? Int64, userId > 0 else { return }
                self?.streaks(userId: userId).sessionDidChange()
                if notification.name == WhitegramBackendSessionMigration.completed { self?.refreshAccess(userId: userId) }
            })
        }
        observers.append(whitegramServiceObserve(WhitegramBackendAccessStore.updated) { [weak self] notification in
            guard let userId = notification.userInfo?["userId"] as? Int64 else { return }
            self?.sessions[userId]?.sessionDidChange()
        })
        observers.append(whitegramServiceObserve(UIApplication.didBecomeActiveNotification) { [weak self] _ in self?.flush() })
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            if UIApplication.shared.applicationState == .active { self?.flush() }
        }
    }

    func streaks(userId: Int64) -> WhitegramProfileStreakSession {
        precondition(Thread.isMainThread && userId > 0)
        if let session = sessions[userId] { return session }
        let session = WhitegramProfileStreakSession(client: WhitegramBackendClient(userId: userId), enabled: { WhitegramPreferences.bool("whitegramStreakEnabled") })
        sessions[userId] = session
        return session
    }

    private func refreshAccess(userId: Int64) {
        let client = WhitegramBackendClient(userId: userId)
        guard accessTasks[userId] == nil, (try? client.hasSession()) == true,
              client.access.state(userId: userId, now: Date()) == .unknown else { return }
        accessTasks[userId] = client.refreshAccess { [weak self] _ in self?.accessTasks.removeValue(forKey: userId) }
    }

    private func flush() {
        for (userId, session) in sessions { refreshAccess(userId: userId); session.process() }
    }
}

public func whitegramInstallBackend() {
    precondition(Thread.isMainThread)
    _ = WhitegramBackendActivityRuntime.shared
}

public func whitegramRegisterBackendAccount(userId: Int64) {
    guard userId > 0 else { return }
    DispatchQueue.main.async {
        _ = WhitegramBackendActivityRuntime.shared.streaks(userId: userId)
        WhitegramBackendSessionMigration.schedule(userId: userId)
    }
}
