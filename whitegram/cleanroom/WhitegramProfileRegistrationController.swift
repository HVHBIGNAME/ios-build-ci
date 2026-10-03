import Foundation
import UIKit
import AccountContext
import Display
import TelegramCore
import SwiftSignalKit

private final class WhitegramProfileRegistrationCoordinator: WhitegramServiceListActions {
    let entries = ValuePromise<[WhitegramServiceEntry]>([], ignoreRepeated: true)
    let presenter = WhitegramServicePresenter()
    private let userId: Int64
    private let service: WhitegramProfileService
    private var date: WhitegramProfileRegistrationDate?
    private var task: WhitegramBackendTask?
    private var busy = false
    private var error: String?

    init(context: AccountContext, userId: Int64) {
        self.userId = userId
        service = WhitegramProfileService(client: WhitegramBackendClient(userId: context.account.peerId.id._internalGetInt64Value()))
        refresh()
    }
    deinit { task?.cancel() }
    func setEnabled(_ enabled: Bool) {}

    func load() {
        guard !busy else { return }
        busy = true; error = nil; refresh()
        task = service.registrationDate(userId: userId, force: true) { [weak self] result in
            guard let self else { return }
            busy = false; task = nil
            switch result {
            case let .success(value): date = value
            case let .failure(value): date = nil; error = value.localizedDescription
            }
            refresh()
        }
    }

    private func save(year: Int, month: Int, day: Int) {
        guard !busy, userId == service.client.userId else { return }
        do {
            busy = true; error = nil; refresh()
            task = try service.saveRegistrationDate(year: year, month: month, day: day) { [weak self] result in
                guard let self else { return }
                busy = false; task = nil
                if case let .failure(value) = result { error = value.localizedDescription; refresh() }
                else { load() }
            }
        } catch { busy = false; self.error = error.localizedDescription; refresh() }
    }

    func perform(_ id: String) {
        guard !busy else { return }
        if id == "refresh" { load(); return }
        guard id == "edit", userId == service.client.userId else { return }
        let alert = UIAlertController(title: WhitegramLocalization.string("profile.registrationDate"),
            message: WhitegramLocalization.string("profile.registrationDate.editorHint"), preferredStyle: .alert)
        for (key, value) in [("year", date?.year ?? 0), ("month", date?.month ?? 0), ("day", date?.day ?? 0)] {
            alert.addTextField { field in
                field.placeholder = WhitegramLocalization.string("profile.registrationDate." + key)
                field.keyboardType = .numberPad
                field.text = value == 0 ? "" : String(value)
            }
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.presenter.close() })
        alert.addAction(UIAlertAction(title: "Publish date", style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields, fields.count == 3 else { return }
            let values = fields.map { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            presenter.close()
            guard let year = Int(values[0]), let month = values[1].isEmpty ? 0 : Int(values[1]),
                  let day = values[2].isEmpty ? 0 : Int(values[2]), year > 0 else {
                error = "Enter a year and optional month and day."; refresh(); return
            }
            save(year: year, month: month, day: day)
        })
        if date?.isEmpty == false {
            alert.addAction(UIAlertAction(title: "Remove published date", style: .destructive) { [weak self] _ in
                self?.presenter.close(); self?.save(year: 0, month: 0, day: 0)
            })
        }
        if !presenter.present(alert) { error = "The date editor could not be opened."; refresh() }
    }

    private func refresh() {
        var rows: [WhitegramServiceEntry] = []
        func add(_ id: String, _ content: WhitegramServiceEntry.Content) {
            rows.append(WhitegramServiceEntry(stableId: id, order: rows.count, section: 0, content: content))
        }
        add("user", .text("Profile: \(userId)"))
        add("date", .text(date?.displayText ?? "No current registration date."))
        add("refresh", .action(busy ? "Loading…" : "Refresh", !busy))
        if userId == service.client.userId { add("edit", .action(WhitegramLocalization.string("profile.registrationDate.add"), !busy)) }
        if let date, !date.isEmpty { add("precision", .text(date.exact ? "Exact date reported by the service." : "Approximate date reported by the service.")) }
        if let error { add("error", .text(error)) }
        entries.set(rows)
    }
}

public func whitegramProfileRegistrationController(context: AccountContext, userId: Int64) -> ViewController {
    let coordinator = WhitegramProfileRegistrationCoordinator(context: context, userId: userId)
    let controller = whitegramServiceListController(context: context, title: WhitegramLocalization.string("profile.registrationDate"), entries: coordinator.entries.get(), actions: coordinator)
    coordinator.presenter.controller = controller
    controller.didAppear = { [coordinator] _ in coordinator.load() }
    return controller
}
