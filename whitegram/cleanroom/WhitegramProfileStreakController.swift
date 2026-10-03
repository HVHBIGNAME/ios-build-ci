import Foundation
import AccountContext
import Display
import TelegramCore
import SwiftSignalKit

private final class WhitegramProfileStreakCoordinator: WhitegramServiceListActions {
    let entries = ValuePromise<[WhitegramServiceEntry]>([], ignoreRepeated: true)
    private let session: WhitegramProfileStreakSession
    private let peerId: Int64?
    private var task: WhitegramBackendTask?
    private var observer: NSObjectProtocol?
    private var streaks: [WhitegramProfileStreak] = []
    private var busy = false
    private var loaded = false
    private var error: String?

    init(context: AccountContext, peerId: Int64?) {
        self.peerId = peerId
        session = WhitegramBackendActivityRuntime.shared.streaks(userId: context.account.peerId.id._internalGetInt64Value())
        observer = whitegramServiceObserve(WhitegramProfileStreakSession.updated) { [weak self] notification in
            guard let self, notification.object as AnyObject? === session else { return }
            refresh()
        }
        refresh()
    }
    deinit { task?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }

    func setEnabled(_ enabled: Bool) {
        error = WhitegramPreferences.set(enabled, for: "whitegramStreakEnabled") ? nil : "Could not save the streak setting."
        session.settingsDidChange()
        refresh()
    }

    func load() {
        guard !busy else { return }
        busy = true; error = nil; refresh()
        let completion: (Result<[WhitegramProfileStreak], WhitegramBackendError>) -> Void = { [weak self] result in
            guard let self else { return }
            busy = false; task = nil
            switch result {
            case let .success(values): streaks = values; loaded = true
            case let .failure(value): error = value.localizedDescription; streaks = []; loaded = false
            }
            refresh()
        }
        if let peerId { task = session.service.state(peerId: peerId) { completion($0.map { [$0] }) } }
        else { task = session.service.list(completion: completion) }
    }

    func perform(_ id: String) {
        if id == "refresh" { load() }
        else if id == "retry" { session.sessionDidChange(); load() }
    }

    private func refresh() {
        var rows: [WhitegramServiceEntry] = []
        func add(_ id: String, _ content: WhitegramServiceEntry.Content, section: Int32 = 0) {
            rows.append(WhitegramServiceEntry(stableId: id, order: rows.count, section: section, content: content))
        }
        add("enabled", .toggle(WhitegramLocalization.string("s.whitegramStreak"), WhitegramPreferences.bool("whitegramStreakEnabled"), true))
        add("info", .text(WhitegramLocalization.string("wh.whitegramStreak")))
        add("refresh", .action(busy ? "Loading…" : "Refresh streaks", !busy))
        if let synchronized = session.synchronizedEnabled { add("sync", .text("Server setting: " + (synchronized ? "On" : "Off"))) }
        else { add("sync", .text("Server setting has not been synchronized.")) }
        if session.pendingCount > 0 { add("pending", .text("Pending confirmed-message reports: \(session.pendingCount)")) }
        if loaded && streaks.isEmpty { add("empty", .text("No streaks reported by the service."), section: 1) }
        for streak in streaks {
            let prefix = String(streak.peerId)
            add(prefix, .header("\(streak.peerId) · \(streak.streakDays) days"), section: 1)
            add(prefix + ".active", .text(WhitegramLocalization.string(streak.isActiveToday ? "auto.WGStreakInfoViewController.72ff005a4a" : "streak.info.task.reply")), section: 1)
            add(prefix + ".talking", .text("Days in contact: \(streak.talkingDays)"), section: 1)
            if let level = streak.serverFlameLevel { add(prefix + ".flame", .text("Flame level: \(level)"), section: 1) }
            if let milestone = streak.nextMilestone { add(prefix + ".next", .text("Next milestone: \(milestone) days"), section: 1) }
            if let reached = streak.reachedMilestone { add(prefix + ".reached", .text("Reached milestone: \(reached) days"), section: 1) }
        }
        if let value = session.lastError { add("syncError", .text(value.localizedDescription), section: 2); add("retry", .action("Retry synchronization", !busy), section: 2) }
        if let error { add("error", .text(error), section: 2) }
        entries.set(rows)
    }
}

public func whitegramProfileStreakController(context: AccountContext, peerId: Int64? = nil) -> ViewController {
    let coordinator = WhitegramProfileStreakCoordinator(context: context, peerId: peerId)
    let controller = whitegramServiceListController(context: context, title: WhitegramLocalization.string("s.whitegramStreak"), entries: coordinator.entries.get(), actions: coordinator)
    controller.didAppear = { [coordinator] _ in coordinator.load() }
    return controller
}
