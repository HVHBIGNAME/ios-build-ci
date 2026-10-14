import AccountContext
import Display
import Foundation
import SwiftSignalKit
import TelegramCore
import UIKit

private final class WhitegramVisualUsernameCoordinator: WhitegramServiceListActions {
    let entries = ValuePromise<[WhitegramServiceEntry]>([], ignoreRepeated: true)
    let presenter = WhitegramServicePresenter()
    private let context: AccountContext
    private var observer: NSObjectProtocol?
    private var status: String?

    init(context: AccountContext) {
        self.context = context
        self.presenter.changed = { [weak self] in self?.refresh() }
        self.observer = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        self.refresh()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func localized(_ key: String) -> String {
        return WhitegramLocalization.string(key, baseLanguage: context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode })
    }

    func setEnabled(_ enabled: Bool) { save(["visualUsernameEnabled": enabled]) }

    private func save(_ values: [String: Any]) {
        self.status = WhitegramPreferences.update(values) ? nil : "Could not save settings."
        self.refresh()
    }

    private func refresh() {
        let policy = WhitegramAppearancePolicy.current
        let enabled = !presenter.isPresenting
        var rows = [
            WhitegramServiceEntry(stableId: "enabled", order: 0, section: 0, content: .toggle(localized("s.visualUsername"), policy.isEnabled("visualUsernameEnabled"), enabled)),
            WhitegramServiceEntry(stableId: "edit", order: 1, section: 0, content: .disclosure(localized("s.visualUsernameLbl"), policy.visualUsername, enabled)),
            WhitegramServiceEntry(stableId: "info", order: 2, section: 1, content: .text(localized("wh.visualUsername"))),
            WhitegramServiceEntry(stableId: "reset", order: 3, section: 1, content: .action(localized("common.reset"), enabled))
        ]
        if let status { rows.append(WhitegramServiceEntry(stableId: "status", order: 4, section: 2, content: .text(status))) }
        self.entries.set(rows)
    }

    func perform(_ id: String) {
        guard !presenter.isPresenting else { return }
        if id == "reset" { save(["visualUsernameEnabled": false, "visualUsername": ""]); return }
        guard id == "edit" else { return }
        let alert = UIAlertController(title: localized("s.visualUsernameLbl"), message: "A–Z, a–z, 0–9, _ · 1–32", preferredStyle: .alert)
        alert.addTextField {
            $0.text = WhitegramAppearancePolicy.current.visualUsername
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.keyboardType = .asciiCapable
        }
        alert.addAction(UIAlertAction(title: localized("common.cancel"), style: .cancel, handler: { [weak self] _ in self?.presenter.close() }))
        alert.addAction(UIAlertAction(title: localized("common.save"), style: .default, handler: { [weak self, weak alert] _ in
            guard let self else { return }
            self.presenter.close()
            guard let value = WhitegramVisualUsername.normalized(alert?.textFields?.first?.text ?? "") else {
                self.status = "A–Z, a–z, 0–9, _ · 1–32"
                self.refresh()
                return
            }
            self.save(["visualUsername": value])
        }))
        self.presenter.present(alert)
    }
}

public func whitegramVisualUsernameController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramVisualUsernameCoordinator(context: context)
    let controller = whitegramServiceListController(context: context, title: "Username", entries: coordinator.entries.get(), actions: coordinator, titleKey: "s.visualUsernameLbl")
    coordinator.presenter.controller = controller
    return controller
}
