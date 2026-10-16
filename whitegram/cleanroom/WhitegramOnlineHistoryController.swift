import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext

private final class WhitegramOnlineHistoryCoordinator {
    let context: AccountContext
    let store: WhitegramOnlineHistoryStore
    let revision = ValuePromise<Int>(0, ignoreRepeated: true)
    weak var controller: ViewController?
    var entries: [WhitegramOnlineHistoryEntry] = []
    var query = WhitegramOnlineHistoryQuery()
    var limit = WhitegramOnlineHistoryStore.pageSize
    var failed = false
    private var generation = 0
    private var observers: [NSObjectProtocol] = []

    init(context: AccountContext) {
        self.context = context
        self.store = WhitegramOnlineHistoryStore.forAccount(context.account.peerId.toInt64())
        observers.append(NotificationCenter.default.addObserver(forName: WhitegramOnlineHistoryStore.updatedNotification, object: store, queue: .main) { [weak self] _ in self?.reload() })
        for name in [WhitegramPreferences.updatedNotification, WhitegramLocalizationStore.changedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.changed() })
        }
        self.reload()
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func text(_ english: String, _ russian: String) -> String {
        let base = context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode }
        return WhitegramLocalization.selectedLanguage(baseLanguage: base) == "ru" ? russian : english
    }

    func changed() { generation += 1; revision.set(generation) }
    func queryChanged() { limit = WhitegramOnlineHistoryStore.pageSize; changed() }

    func reload() {
        store.snapshot { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(entries): self.entries = entries; self.failed = false
            case .failure: self.entries = []; self.failed = true
            }
            self.changed()
        }
    }

    func toggle(_ value: Bool) {
        if !WhitegramPreferences.set(value, for: "onlineHistoryEnabled") { self.error() }
    }

    private func error() {
        let alert = UIAlertController(title: "Whitegram", message: text("Could not save the change.", "Не удалось сохранить изменение."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        controller?.present(alert, animated: true)
    }

    func clear() {
        let alert = UIAlertController(title: text("Clear online history?", "Очистить историю онлайна?"),
            message: text("Remove all online-history records for this account, including hidden pages and other filters?", "Удалить все записи истории онлайна этого аккаунта, включая скрытые страницы и другие фильтры?"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: text("Cancel", "Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: text("Clear", "Очистить"), style: .destructive, handler: { [weak self] _ in
            self?.store.clear { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: self.query = WhitegramOnlineHistoryQuery(); self.queryChanged(); self.reload()
                case .failure: self.error()
                }
            }
        }))
        controller?.present(alert, animated: true)
    }

    private func search() {
        let alert = UIAlertController(title: text("Find contact", "Найти контакт"), message: text("Name, username or peer ID", "Имя, username или ID контакта"), preferredStyle: .alert)
        alert.addTextField { $0.text = self.query.text }
        alert.addAction(UIAlertAction(title: text("Cancel", "Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: text("Search", "Найти"), style: .default, handler: { [weak self, weak alert] _ in
            self?.query.text = alert?.textFields?.first?.text ?? ""
            self?.queryChanged()
        }))
        controller?.present(alert, animated: true)
    }

    private func selectDate() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        formatter.calendar = calendar
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let alert = UIAlertController(title: text("Filter by date", "Фильтр по дате"), message: "YYYY-MM-DD", preferredStyle: .alert)
        alert.addTextField { $0.text = self.query.date.map { formatter.string(from: $0.start) } }
        alert.addAction(UIAlertAction(title: text("Cancel", "Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: text("All dates", "Все даты"), style: .default, handler: { [weak self] _ in
            self?.query.date = nil; self?.queryChanged()
        }))
        alert.addAction(UIAlertAction(title: text("Apply", "Применить"), style: .default, handler: { [weak self, weak alert] _ in
            guard let self else { return }
            let input = alert?.textFields?.first?.text ?? ""
            guard let day = formatter.date(from: input), formatter.string(from: day) == input,
                  let interval = formatter.calendar.dateInterval(of: .day, for: day) else {
                let error = UIAlertController(title: self.text("Invalid date", "Некорректная дата"), message: "YYYY-MM-DD", preferredStyle: .alert)
                error.addAction(UIAlertAction(title: "OK", style: .default))
                self.controller?.present(error, animated: true)
                return
            }
            self.query.date = interval
            self.queryChanged()
        }))
        controller?.present(alert, animated: true)
    }

    func action(_ id: String) {
        switch id {
        case "search": search()
        case "date": selectDate()
        case "all": query = WhitegramOnlineHistoryQuery(); queryChanged()
        case "clear": clear()
        case "reload": reload()
        case "more": limit += WhitegramOnlineHistoryStore.pageSize; changed()
        default:
            if let entry = entries.first(where: { $0.id.uuidString == id }) {
                query.peerId = entry.peerId
                queryChanged()
            }
        }
    }

    func rows(presentationData: PresentationData) -> [WhitegramHistoryRow] {
        var rows: [WhitegramHistoryRow] = []
        func row(_ id: String, _ title: String, detail: String = "", section: ItemListSectionId = 0, info: Bool = false, value: Bool? = nil) {
            rows.append(WhitegramHistoryRow(id: id, index: rows.count, section: section, title: title, detail: detail, value: value, isInfo: info))
        }
        let base = presentationData.strings.baseLanguageCode
        row("enabled", WhitegramLocalization.string("s.onlineHistory", baseLanguage: base), value: WhitegramPreferences.bool("onlineHistoryEnabled", default: UserDefaults.standard.bool(forKey: "wg_onlineHistoryEnabled")))
        row("search", text("Find contact", "Найти контакт"), detail: query.text)
        let selectedDate = query.date.map { DateFormatter.localizedString(from: $0.start, dateStyle: .medium, timeStyle: .none) } ?? ""
        row("date", text("Filter by date", "Фильтр по дате"), detail: selectedDate)
        if let peerId = query.peerId {
            row("peer", entries.last(where: { $0.peerId == peerId })?.peerName ?? String(peerId), info: true)
        }
        row("all", text("All contacts and dates", "Все контакты и даты"))
        row("clear", text("Clear online history", "Очистить историю онлайна"))
        row("reload", text("Refresh", "Обновить"))
        row("scope", text("Only observed contact status changes are stored, while this client receives updates. Tap an event to filter by contact.", "Сохраняются полученные этим клиентом изменения статуса контактов. Нажмите на событие для фильтра по контакту."), info: true)
        if failed {
            row("error", text("Could not read online history. Existing data has not been replaced.", "Не удалось прочитать историю онлайна. Существующие данные не перезаписаны."), info: true)
            return rows
        }
        let matching = query.apply(to: entries)
        row("count", text("Matching: \(matching.count) · Stored: \(entries.count) / \(WhitegramOnlineHistoryStore.maximumEntries)", "Найдено: \(matching.count) · Сохранено: \(entries.count) / \(WhitegramOnlineHistoryStore.maximumEntries)"), info: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: WhitegramLocalization.selectedLanguage(baseLanguage: base))
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        var lastDay: Date?
        var section: ItemListSectionId = 0
        for entry in matching.prefix(limit) {
            let date = Date(timeIntervalSince1970: entry.timestamp)
            let day = Calendar.autoupdatingCurrent.startOfDay(for: date)
            if day != lastDay {
                section += 1
                formatter.dateStyle = .medium; formatter.timeStyle = .none
                row("day:\(entry.id.uuidString)", formatter.string(from: date), section: section, info: true)
                lastDay = day
            }
            formatter.dateStyle = .none; formatter.timeStyle = .medium
            let state = entry.isOnline ? text("Online", "В сети") : text("Offline", "Не в сети")
            row(entry.id.uuidString, entry.peerName, detail: state + " · " + formatter.string(from: date), section: section)
        }
        if matching.isEmpty { row("empty", text("No events match these filters.", "По этим фильтрам событий нет."), section: 1, info: true) }
        if matching.count > limit { row("more", text("Show 50 more", "Показать ещё 50"), section: section + 1) }
        return rows
    }
}

public func whitegramOnlineHistoryController(context: AccountContext, clearOnOpen: Bool = false) -> ViewController {
    let coordinator = WhitegramOnlineHistoryCoordinator(context: context)
    let actions = WhitegramHistoryListActions(select: { coordinator.action($0) }, toggle: { _, value in coordinator.toggle(value) })
    let signal = combineLatest(context.sharedContext.presentationData, coordinator.revision.get())
    |> deliverOnMainQueue
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(WhitegramLocalization.string("m.onlineHistory", baseLanguage: presentationData.strings.baseLanguageCode)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: coordinator.rows(presentationData: presentationData), style: .blocks, animateChanges: false), actions))
    }
    let controller = ItemListController(context: context, state: signal)
    coordinator.controller = controller
    if clearOnOpen {
        controller.didAppear = { firstTime in if firstTime { coordinator.clear() } }
    }
    return controller
}
