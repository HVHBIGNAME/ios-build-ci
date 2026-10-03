import Foundation
import UIKit
import AccountContext
import Display
import SwiftSignalKit
import TelegramCore

private final class WhitegramTrafficCoordinator: WhitegramServiceListActions {
    let entries = ValuePromise<[WhitegramServiceEntry]>([], ignoreRepeated: true)
    private var observer: NSObjectProtocol?
    private var error: String?

    init() {
        WhitegramTrafficManager.install()
        observer = NotificationCenter.default.addObserver(forName: WhitegramTrafficManager.updated, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func setEnabled(_ enabled: Bool) {
        error = WhitegramPreferences.set(enabled, for: "antiCensorshipEnabled") ? nil : "Could not save the traffic setting."
        WhitegramTrafficManager.shared.refresh()
        refresh()
    }
    func perform(_ id: String) {}

    private func refresh() {
        let manager = WhitegramTrafficManager.shared
        var rows: [WhitegramServiceEntry] = []
        func add(_ id: String, _ content: WhitegramServiceEntry.Content) {
            rows.append(WhitegramServiceEntry(stableId: id, order: rows.count, section: 0, content: content))
        }
        add("enabled", .toggle("Improved traffic", WhitegramPreferences.bool("antiCensorshipEnabled"), true))
        add("description", .text("Sends periodic GET/HEAD requests to the original eight public CDN and web endpoints while Whitegram is active. This generates decoy traffic; Telegram's transport and encryption remain as provided by Telegram."))
        add("state", .text(manager.status))
        if let date = manager.nextRequestAt { add("next", .text("Next request: " + whitegramServiceDate(date))) }
        if let result = manager.lastResult { add("last", .text(result)) }
        add("requests", .text("Decoy requests this launch: \(manager.requestCount)"))
        add("endpoints", .text(WhitegramTrafficPolicy.endpoints.joined(separator: "\n")))
        if let error { add("error", .text(error)) }
        entries.set(rows)
    }
}

public func whitegramTrafficController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramTrafficCoordinator()
    return whitegramServiceListController(context: context, title: "Improved traffic", entries: coordinator.entries.get(), actions: coordinator)
}
