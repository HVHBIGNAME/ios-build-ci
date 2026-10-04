import Foundation
import UIKit
import AccountContext
import Display
import TelegramCore
import SwiftSignalKit

private final class WhitegramProfileWallCoordinator: WhitegramServiceListActions {
    let entries = ValuePromise<[WhitegramServiceEntry]>([], ignoreRepeated: true)
    let presenter = WhitegramServicePresenter()
    private let context: AccountContext
    private let ownerId: Int64
    private let service: WhitegramProfileService
    private var state: WhitegramProfileWallState?
    private var blockedUsers: [WhitegramProfileBlockedUser] = []
    private var ownName: String?
    private var nameDisposable: Disposable?
    private var task: WhitegramBackendTask?
    private var timer: Foundation.Timer?
    private var revision = 0
    private var busy = false
    private var error: String?
    private var visible = false
    private var ticks = 0

    init(context: AccountContext, userId: Int64) {
        self.context = context
        ownerId = userId
        service = WhitegramProfileService(client: WhitegramBackendClient(userId: context.account.peerId.id._internalGetInt64Value()))
        nameDisposable = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
        |> deliverOnMainQueue).start(next: { [weak self] peer in self?.ownName = peer?.compactDisplayTitle; self?.refresh() })
        refresh()
    }
    deinit { task?.cancel(); timer?.invalidate(); nameDisposable?.dispose() }
    private var canManage: Bool { return ownerId == service.client.userId }
    func setEnabled(_ enabled: Bool) {}

    func appeared() {
        visible = true
        timer?.invalidate()
        timer = Foundation.Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, visible, UIApplication.shared.applicationState == .active else { return }
            ticks += 1
            if ticks % 30 == 0 && !busy && !presenter.isPresenting { reload() }
            else { refresh() }
        }
        reload()
    }

    func disappeared() {
        guard !presenter.isPresenting else { return }
        visible = false
        timer?.invalidate()
        timer = nil
    }

    private func reload() {
        guard !busy else { return }
        busy = true
        revision += 1
        let revision = self.revision
        refresh()
        task = service.fetch(WhitegramProfileWallState.self, resource: .wall, userId: ownerId, force: true) { [weak self] result in
            guard let self, revision == self.revision else { return }
            complete(result)
        }
    }

    private func complete(_ result: Result<WhitegramProfileWallState, WhitegramBackendError>) {
        busy = false
        task = nil
        switch result {
        case let .success(value): state = value; error = nil
        case let .failure(value): state = nil; blockedUsers = []; error = value.localizedDescription
        }
        refresh()
    }

    private func edit(_ message: WhitegramProfileWallMessage?) {
        guard !busy else { return }
        let editor = WhitegramProfileTextEditor(title: message == nil ? "Write on profile wall" : "Edit wall message", text: message?.text ?? "", maximumLength: 4096,
            message: "Save sends this text to the profile wall. Editing replaces rich-text formatting.", saved: { [weak self] text in
                guard let self else { return }
                presenter.close()
                busy = true; error = nil; refresh()
                do {
                    if let message {
                        task = try service.edit(ownerId: ownerId, messageId: message.id, text: text,
                            entities: message.text == text ? message.entities : []) { [weak self] in self?.complete($0) }
                    } else {
                        guard let state, state.canPost(at: Date()), let ownName else { throw WhitegramBackendError.invalidRequest }
                        task = try service.send(ownerId: ownerId, text: text, entities: [], authorName: ownName) { [weak self] in self?.complete($0) }
                    }
                } catch { busy = false; self.error = error.localizedDescription; refresh() }
            }, cancelled: { [weak self] in self?.presenter.close() })
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .formSheet
        if !presenter.present(navigation) { error = "The message editor could not be opened."; refresh() }
    }

    private func actions(for message: WhitegramProfileWallMessage) {
        let alert = UIAlertController(title: message.authorName, message: message.text, preferredStyle: .actionSheet)
        if message.authorId == service.client.userId {
            alert.addAction(UIAlertAction(title: "Edit", style: .default) { [weak self] _ in
                self?.presenter.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.edit(message) }
            })
        }
        if canManage || message.authorId == service.client.userId {
            alert.addAction(UIAlertAction(title: "Delete from wall", style: .destructive) { [weak self] _ in
                guard let self else { return }
                presenter.close()
                busy = true; refresh()
                do { task = try service.delete(ownerId: ownerId, ids: [message.id]) { [weak self] in self?.complete($0) } }
                catch { busy = false; self.error = error.localizedDescription; refresh() }
            })
        }
        if canManage && message.authorId != ownerId {
            alert.addAction(UIAlertAction(title: "Block author on this wall", style: .destructive) { [weak self] _ in
                guard let self else { return }
                presenter.close()
                mutate { self.service.block(true, userId: message.authorId, ownerId: self.ownerId, completion: $0) }
            })
        }
        alert.addAction(UIAlertAction(title: "Copy text", style: .default) { [weak self] _ in whitegramServiceCopy(message.text); self?.presenter.close() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.presenter.close() })
        alert.popoverPresentationController?.sourceView = presenter.controller?.view
        alert.popoverPresentationController?.sourceRect = CGRect(x: 30, y: 100, width: 1, height: 1)
        if !presenter.present(alert) { error = "The wall menu could not be opened."; refresh() }
    }

    private func mutate(_ request: (@escaping (Result<Void, WhitegramBackendError>) -> Void) -> WhitegramBackendTask, succeeded: @escaping () -> Void = {}) {
        guard !busy else { return }
        busy = true; error = nil; refresh()
        task = request { [weak self] result in
            guard let self else { return }
            busy = false
            task = nil
            if case let .failure(value) = result { error = value.localizedDescription; refresh() }
            else { succeeded(); reload() }
        }
    }

    func perform(_ id: String) {
        guard !busy else { return }
        if id == "refresh" { reload() }
        else if id == "write", state?.canPost(at: Date()) == true { edit(nil) }
        else if id == "enabled", canManage, let state {
            mutate { service.save(WhitegramProfileRequests.Enabled(enabled: !state.enabled), path: "/v1/wall/settings", completion: $0) }
        } else if id == "blocked", canManage {
            busy = true; refresh()
            task = service.blocked(ownerId: ownerId) { [weak self] result in
                guard let self else { return }
                busy = false; task = nil
                switch result {
                case let .success(users): blockedUsers = users
                case let .failure(value): error = value.localizedDescription
                }
                refresh()
            }
        } else if id.hasPrefix("unblock:"), canManage, let userId = Int64(id.dropFirst(8)) {
            mutate({ service.block(false, userId: userId, ownerId: ownerId, completion: $0) }, succeeded: { [weak self] in
                self?.blockedUsers.removeAll { $0.userId == userId }
            })
        } else if let message = state?.messages.first(where: { "message:" + $0.id == id }) { actions(for: message) }
    }

    private func refresh() {
        var rows: [WhitegramServiceEntry] = []
        func add(_ id: String, _ content: WhitegramServiceEntry.Content, section: Int32 = 0) {
            rows.append(WhitegramServiceEntry(stableId: id, order: rows.count, section: section, content: content))
        }
        add("owner", .text("Profile wall: \(ownerId)"))
        if canManage { add("enabled", .disclosure("Wall enabled", state.map { $0.enabled ? "On" : "Off" } ?? "Not loaded", !busy && state != nil)) }
        add("refresh", .action(busy ? "Loading…" : "Refresh", !busy))
        add("write", .action("Write a message", !busy && state?.canPost(at: Date()) == true && ownName != nil))
        if state?.blocked == true { add("blockedState", .text("You are blocked from posting on this wall.")) }
        if let date = state?.nextAllowedAt, Double(date) > Date().timeIntervalSince1970 {
            add("cooldown", .text("You can post in \(Int(ceil(Double(date) - Date().timeIntervalSince1970))) seconds."))
        }
        if let state {
            if state.messages.isEmpty { add("empty", .text("No wall messages."), section: 1) }
            for message in state.messages {
                add("message:" + message.id, .disclosure(message.authorName + " · " + whitegramServiceDate(Date(timeIntervalSince1970: Double(message.timestamp))), message.text, !busy), section: 1)
            }
        }
        if canManage {
            add("blocked", .action("Load blocked users", !busy), section: 2)
            for user in blockedUsers { add("unblock:\(user.userId)", .disclosure("\(user.userId)", "Unblock", !busy), section: 2) }
        }
        if let error { add("error", .text(error), section: 3) }
        entries.set(rows)
    }
}

public func whitegramProfileWallController(context: AccountContext, userId: Int64) -> ViewController {
    let coordinator = WhitegramProfileWallCoordinator(context: context, userId: userId)
    let controller = whitegramServiceListController(context: context, title: "Profile Wall", entries: coordinator.entries.get(), actions: coordinator)
    coordinator.presenter.controller = controller
    controller.didAppear = { [coordinator] _ in coordinator.appeared() }
    controller.didDisappear = { [coordinator] _ in coordinator.disappeared() }
    return controller
}
