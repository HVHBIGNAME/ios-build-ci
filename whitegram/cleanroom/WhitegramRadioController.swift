import Foundation
import AccountContext
import Display
import SwiftSignalKit
import TelegramCore

private final class WhitegramRadioCoordinator: WhitegramServiceListActions {
    let entries = ValuePromise<[WhitegramServiceEntry]>([], ignoreRepeated: true)
    private let context: AccountContext
    private let client: WhitegramBackendClient
    private let authentication: WhitegramBackendAuthentication
    private var observer: NSObjectProtocol?
    private var connecting = false
    private var error: String?

    init(context: AccountContext) {
        self.context = context
        client = WhitegramBackendClient(userId: context.account.peerId.id._internalGetInt64Value())
        authentication = WhitegramBackendAuthentication(context: context, client: client)
        observer = NotificationCenter.default.addObserver(forName: WhitegramRadioPlayer.updated, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        refresh()
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func setEnabled(_ enabled: Bool) {}

    func perform(_ id: String) {
        let player = WhitegramRadioPlayer.shared
        if let station = WhitegramRadioStation.all.first(where: { $0.id == id }) { player.play(station, context: context, client: client); return }
        switch id {
        case "stop": player.stop()
        case "pause": player.pause()
        case "resume": player.resume()
        case "listeners": player.refreshListeners()
        case "presence":
            error = WhitegramPreferences.set(!WhitegramPreferences.bool("whitegramPresenceEnabled"), for: "whitegramPresenceEnabled") ? nil : "Could not save the presence setting."
            refresh()
        case "precise":
            error = WhitegramPreferences.set(!WhitegramPreferences.bool("whitegramPresencePreciseEnabled"), for: "whitegramPresencePreciseEnabled") ? nil : "Could not save the presence setting."
            refresh()
        case "connect":
            guard !connecting else { return }
            connecting = true
            error = nil
            refresh()
            authentication.connect { [weak self] result in
                guard let self else { return }
                connecting = false
                if case let .failure(value) = result { error = value.localizedDescription }
                else { player.refreshListeners() }
                refresh()
            }
        default: break
        }
    }

    private func refresh() {
        let player = WhitegramRadioPlayer.shared
        var rows: [WhitegramServiceEntry] = []
        func add(_ id: String, _ content: WhitegramServiceEntry.Content, section: Int32 = 0) {
            rows.append(WhitegramServiceEntry(stableId: id, order: rows.count, section: section, content: content))
        }
        for station in WhitegramRadioStation.all {
            add(station.id, .disclosure(station.name, player.station == station ? "Selected" : "", true))
        }
        if let station = player.station {
            add("station", .header(station.name), section: 1)
            let state: String
            switch player.state {
            case .stopped: state = "Stopped"
            case .waiting: state = "Buffering…"
            case .playing: state = "Playing"
            case .paused: state = "Paused"
            case let .failed(error): state = error
            }
            add("state", .text(state), section: 1)
            if let track = player.track { add("track", .text([track.artist, track.title].filter { !$0.isEmpty }.joined(separator: " — ")), section: 1) }
            add(player.state == .paused ? "resume" : "pause", .action(player.state == .paused ? "Resume" : "Pause", true), section: 1)
            add("stop", .action(WhitegramLocalization.string("radio.stop"), true), section: 1)
            add("listeners", .action("Refresh listener count", true), section: 2)
        }
        if let count = player.listeners { add("count", .text("Listeners: \(count)"), section: 2) }
        add("connect", .action(connecting ? "Connecting…" : "Connect Whitegram radio services", !connecting), section: 2)
        add("connectionInfo", .text("Station audio is public. Listener counts and listening heartbeats use the original Whitegram service and require authorization through its Telegram mini app."), section: 2)
        add("presence", .disclosure(WhitegramLocalization.string("s.whitegramPresence"), WhitegramPreferences.bool("whitegramPresenceEnabled") ? "On" : "Off", true), section: 2)
        add("precise", .disclosure(WhitegramLocalization.string("s.whitegramPresencePrecise"), WhitegramPreferences.bool("whitegramPresencePreciseEnabled") ? "On" : "Off", WhitegramPreferences.bool("whitegramPresenceEnabled")), section: 2)
        if let value = player.metadataError { add("metadataError", .text(value), section: 3) }
        if let value = player.serviceError { add("serviceError", .text(value), section: 3) }
        if let value = player.listenerError { add("listenerError", .text(value), section: 3) }
        if let value = player.presenceError { add("presenceError", .text(value), section: 3) }
        if let error { add("error", .text(error), section: 3) }
        entries.set(rows)
    }
}

public func whitegramRadioController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramRadioCoordinator(context: context)
    return whitegramServiceListController(context: context, title: WhitegramLocalization.string("radio.title"), entries: coordinator.entries.get(), actions: coordinator)
}
