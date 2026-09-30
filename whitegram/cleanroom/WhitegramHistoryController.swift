import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext

private final class WhitegramHistoryCoordinator: NSObject, UIDocumentPickerDelegate {
    let context: AccountContext
    let store: WhitegramHistoryStore
    let revision = ValuePromise<Int>(0, ignoreRepeated: true)
    let showsChats: Bool
    weak var controller: ViewController?
    var records: [WhitegramHistoryEntry] = []
    var loadError: String?
    var status = ""
    var query: WhitegramHistoryQuery
    var limit = 100
    private var generation = 0
    private var observer: NSObjectProtocol?

    var strings: WhitegramHistoryPresentation { return WhitegramHistoryPresentation(self.context.sharedContext.currentPresentationData.with { $0 }) }
    var matchingEntries: [WhitegramHistoryEntry] { return self.query.apply(to: self.records) }

    init(context: AccountContext, query: WhitegramHistoryQuery, showsChats: Bool) {
        self.context = context
        self.query = query
        self.showsChats = showsChats
        self.store = WhitegramHistoryStore.forAccount(mediaBoxPath: context.account.postbox.mediaBox.basePath, accountPeerId: context.account.peerId)
        super.init()
        self.observer = NotificationCenter.default.addObserver(forName: WhitegramHistoryStore.updatedNotification, object: self.store, queue: .main) { [weak self] _ in self?.reload() }
        self.reload()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func changed() { self.generation += 1; self.revision.set(self.generation) }

    func reload() {
        self.store.snapshot(matching: WhitegramHistoryQuery(order: .captureTime)) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(entries): self.records = entries; self.loadError = nil
            case let .failure(error): self.records = []; self.loadError = error.localizedDescription
            }
            self.changed()
        }
    }

    func toggle(_ key: String, _ value: Bool) {
        self.status = WhitegramPreferences.set(value, for: key) ? "" : self.strings.text("Could not save setting.", "Не удалось сохранить настройку.")
        self.changed()
    }

    private func queryChanged() { self.limit = 100; self.status = ""; self.changed() }

    private func presentSheet(_ sheet: UIAlertController) {
        guard let controller else { return }
        sheet.addAction(UIAlertAction(title: self.strings.text("Cancel", "Отмена"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = controller.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
        controller.present(sheet, animated: true)
    }

    private func selectEvent() {
        let strings = self.strings
        let entries = WhitegramHistoryQuery(scope: self.query.scope, text: self.query.text).apply(to: self.records)
        let sheet = UIAlertController(title: strings.text("Version type", "Тип версии"), message: nil, preferredStyle: .actionSheet)
        let events: [WhitegramHistoryEvent?] = [nil] + WhitegramHistoryEvent.allCases.map { Optional($0) }
        for event in events {
            let count = entries.filter { event == nil || $0.event == event }.count
            sheet.addAction(UIAlertAction(title: "\(strings.event(event)) (\(count))", style: .default, handler: { [weak self] _ in
                self?.query.event = event
                self?.queryChanged()
            }))
        }
        self.presentSheet(sheet)
    }

    private func selectOrder() {
        let strings = self.strings
        let sheet = UIAlertController(title: strings.text("Newest first", "Сначала новые"), message: nil, preferredStyle: .actionSheet)
        for order in WhitegramHistoryOrder.allCases {
            sheet.addAction(UIAlertAction(title: strings.order(order), style: .default, handler: { [weak self] _ in
                self?.query.order = order
                self?.queryChanged()
            }))
        }
        self.presentSheet(sheet)
    }

    private func search() {
        let strings = self.strings
        let alert = UIAlertController(title: strings.text("Search archive", "Поиск в архиве"), message: strings.text("Text, chat, author, message ID or filename", "Текст, чат, автор, ID сообщения или имя файла"), preferredStyle: .alert)
        alert.addTextField { $0.text = self.query.text }
        alert.addAction(UIAlertAction(title: strings.text("Cancel", "Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: strings.text("Clear search", "Сбросить поиск"), style: .default, handler: { [weak self] _ in
            self?.query.text = ""
            self?.queryChanged()
        }))
        alert.addAction(UIAlertAction(title: strings.text("Search", "Найти"), style: .default, handler: { [weak self, weak alert] _ in
            self?.query.text = alert?.textFields?.first?.text ?? ""
            self?.queryChanged()
        }))
        self.controller?.present(alert, animated: true)
    }

    private func clear() {
        let strings = self.strings
        let query = self.query
        let count = self.matchingEntries.count
        guard count > 0 else { return }
        let alert = UIAlertController(title: strings.text("Clear matching versions?", "Удалить найденные версии?"), message: strings.text("Remove \(count) matching archived versions on this device, including all pages. Telegram messages are not deleted.", "Удалить \(count) найденных версий из архива на этом устройстве, включая все страницы. Сообщения в Telegram не удаляются."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: strings.text("Cancel", "Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: strings.text("Clear", "Удалить"), style: .destructive, handler: { [weak self] _ in
            self?.store.clear(matching: query) { [weak self] result in
                guard let self else { return }
                if case let .failure(error) = result { self.status = error.localizedDescription; self.changed() }
                else { self.status = ""; self.reload() }
            }
        }))
        self.controller?.present(alert, animated: true)
    }

    private func export() {
        let query = self.query
        self.store.export(matching: query) { [weak self] result in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let data = try result.get()
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Whitegram-History-\(UUID().uuidString).json")
                    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    DispatchQueue.main.async {
                        if let self { self.share(url) }
                        else { Self.removeExport(url) }
                    }
                } catch {
                    DispatchQueue.main.async { self?.status = error.localizedDescription; self?.changed() }
                }
            }
        }
    }

    private static func removeExport(_ url: URL) {
        DispatchQueue.global(qos: .utility).async {
            do { try FileManager.default.removeItem(at: url) }
            catch { NSLog("Whitegram: history export cleanup failed") }
        }
    }

    private func share(_ url: URL) {
        guard let controller else { Self.removeExport(url); return }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = controller.view
        share.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
        share.completionWithItemsHandler = { _, _, _, _ in Self.removeExport(url) }
        controller.present(share, animated: true)
    }

    func action(_ id: String) {
        guard let controller else { return }
        switch id {
        case "filter": self.selectEvent()
        case "order": self.selectOrder()
        case "search": self.search()
        case "reload": self.reload()
        case "clear": self.clear()
        case "export": self.export()
        case "import":
            let picker = UIDocumentPickerViewController(documentTypes: ["public.json"], in: .import)
            picker.delegate = self
            controller.present(picker, animated: true)
        case "more": self.limit += 100; self.changed()
        case "chats":
            controller.navigationController?.pushViewController(whitegramHistoryListController(context: self.context, query: WhitegramHistoryQuery(event: self.query.event, text: self.query.text, order: self.query.order), showsChats: true), animated: true)
        case "settings":
            controller.navigationController?.pushViewController(whitegramHistoryController(context: self.context), animated: true)
        case "chat":
            if let peerId = self.query.scope.peerId {
                controller.navigationController?.pushViewController(whitegramHistoryController(context: self.context, scope: .peer(peerId)), animated: true)
            }
        default:
            if id.hasPrefix("peer:"), Int64(id.dropFirst(5)) != nil {
                let query = WhitegramHistoryQuery(scope: .peer(String(id.dropFirst(5))), event: self.query.event, text: self.query.text, order: self.query.order)
                controller.navigationController?.pushViewController(whitegramHistoryListController(context: self.context, query: query, showsChats: false), animated: true)
            } else if let entry = self.records.first(where: { "entry:\($0.key)" == id }) {
                controller.navigationController?.pushViewController(whitegramHistoryEntryController(context: self.context, entry: entry), animated: true)
            }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let input = try FileHandle(forReadingFrom: url)
                defer { input.closeFile() }
                let data = input.readData(ofLength: WhitegramHistoryStore.maximumArchiveBytes + 1)
                self?.store.importArchive(data) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case let .success(count): self.status = self.strings.text("Added \(count) new versions to this account's archive.", "В архив этого аккаунта добавлено новых версий: \(count)."); self.reload()
                    case let .failure(error): self.status = error.localizedDescription; self.changed()
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.status = error.localizedDescription; self?.changed() }
            }
        }
    }
}

private func historyRows(_ coordinator: WhitegramHistoryCoordinator, strings: WhitegramHistoryPresentation) -> [WhitegramHistoryRow] {
    var rows: [WhitegramHistoryRow] = []
    func action(_ id: String, _ title: String, detail: String = "", section: ItemListSectionId = 1) {
        rows.append(WhitegramHistoryRow(id: id, index: rows.count, section: section, title: title, detail: detail))
    }
    if coordinator.query.scope == .account && !coordinator.showsChats {
        let switches = [
            ("showDeletedMessages", "Save deleted messages", "Сохранять удалённые сообщения"),
            ("showEditedOriginalText", "Save versions before edits", "Сохранять версии до изменения"),
            ("saveChatHistory", "Save received messages", "Сохранять полученные сообщения"),
            ("hideMyDeletedMessages", "Exclude own deleted messages", "Не сохранять мои удалённые"),
            ("hideMyEditedMessages", "Exclude own edited messages", "Не сохранять мои изменения"),
            ("hideBotDeletedMessages", "Exclude bot deletions", "Не сохранять удалённые у ботов"),
            ("hideBotEditedMessages", "Exclude bot edits", "Не сохранять изменения у ботов")
        ]
        for item in switches {
            rows.append(WhitegramHistoryRow(id: item.0, index: rows.count, section: 0, title: strings.text(item.1, item.2), value: WhitegramPreferences.bool(item.0)))
        }
        action("chats", strings.text("Browse archived chats", "Чаты в архиве"))
        action("import", strings.text("Import JSON", "Импорт JSON"))
    } else {
        action("settings", strings.text("Archive & capture settings", "Архив и настройки сохранения"))
    }
    if let peerId = coordinator.query.scope.peerId {
        let title = coordinator.records.first(where: { $0.peerId == peerId && $0.peerTitle != nil })?.peerTitle ?? peerId
        rows.append(WhitegramHistoryRow(id: "scope", index: rows.count, section: 1, title: "\(title) [\(peerId)]", isInfo: true))
        if case let .message(id) = coordinator.query.scope {
            rows.append(WhitegramHistoryRow(id: "message", index: rows.count, section: 1, title: "\(strings.text("Message", "Сообщение")) \(id.id)", isInfo: true))
            action("chat", strings.text("All archived messages in this chat", "Все сохранённые сообщения этого чата"))
        } else {
            action("chats", strings.text("Browse other chats", "Другие чаты"))
        }
    }
    action("filter", strings.text("Version type", "Тип версии"), detail: strings.event(coordinator.query.event))
    action("search", strings.text("Search", "Поиск"), detail: coordinator.query.text)
    action("order", strings.text("Sort by", "Сортировка"), detail: strings.order(coordinator.query.order))
    action("reload", strings.text("Refresh archive", "Обновить архив"))
    if !coordinator.showsChats {
        action("export", strings.text("Export matching versions", "Экспорт найденных версий"))
        action("clear", strings.text("Clear matching versions", "Удалить найденные версии"))
    }
    let entries = coordinator.matchingEntries
    let status = coordinator.loadError ?? strings.text("\(entries.count) matching versions · \(coordinator.records.count) / \(WhitegramHistoryStore.maximumEntries) in this account", "Найдено версий: \(entries.count) · В аккаунте: \(coordinator.records.count) / \(WhitegramHistoryStore.maximumEntries)")
    rows.append(WhitegramHistoryRow(id: "status", index: rows.count, section: 1, title: status, isInfo: true))
    if !coordinator.status.isEmpty {
        rows.append(WhitegramHistoryRow(id: "operation", index: rows.count, section: 1, title: coordinator.status, isInfo: true))
    }
    rows.append(WhitegramHistoryRow(id: "limits", index: rows.count, section: 1, title: strings.text("Local cloud-message text and attachment metadata. Media files and secret chats are not backed up. Versions missed before capture was enabled cannot be reconstructed.", "Локальный архив текста облачных сообщений и метаданных вложений. Медиафайлы и секретные чаты не резервируются. Пропущенные до включения сохранения версии восстановить нельзя."), isInfo: true))
    if entries.isEmpty && coordinator.loadError == nil {
        rows.append(WhitegramHistoryRow(id: "empty", index: rows.count, section: 2, title: strings.text("No archived versions match. Try another filter, or enable capture for future messages and edits.", "Подходящих версий в архиве нет. Измените фильтр или включите сохранение будущих сообщений и изменений."), isInfo: true))
    }
    if coordinator.showsChats {
        let grouped = Dictionary(grouping: entries, by: { $0.peerId })
        var seen = Set<String>()
        let peers = entries.filter { seen.insert($0.peerId).inserted }
        for entry in peers.prefix(coordinator.limit) {
            let title = grouped[entry.peerId]?.first(where: { $0.peerTitle != nil })?.peerTitle ?? entry.peerId
            rows.append(WhitegramHistoryRow(id: "peer:\(entry.peerId)", index: rows.count, section: 2, title: title, detail: "\(entry.peerId) · \(grouped[entry.peerId]?.count ?? 0) \(strings.text("matching versions", "найденных версий"))"))
        }
        if peers.count > coordinator.limit { action("more", strings.text("Show more chats", "Показать ещё чаты"), section: 2) }
    } else {
        for entry in entries.prefix(coordinator.limit) {
            rows.append(WhitegramHistoryRow(id: "entry:\(entry.key)", index: rows.count, section: 2, title: strings.summary(entry), detail: "\(strings.event(entry.event)) · \(entry.peerTitle ?? entry.peerId)\n\(strings.text("Sent", "Отправлено")): \(strings.date(Double(entry.messageDate)))", additionalDetail: "\(strings.text("Captured", "Сохранено")): \(strings.date(entry.capturedAt))"))
        }
        if entries.count > coordinator.limit { action("more", strings.text("Show more versions", "Показать ещё версии"), section: 2) }
    }
    return rows
}

private func whitegramHistoryListController(context: AccountContext, query: WhitegramHistoryQuery, showsChats: Bool) -> ViewController {
    let coordinator = WhitegramHistoryCoordinator(context: context, query: query, showsChats: showsChats)
    let actions = WhitegramHistoryListActions(select: { coordinator.action($0) }, toggle: { coordinator.toggle($0, $1) })
    let signal = combineLatest(context.sharedContext.presentationData, coordinator.revision.get())
    |> deliverOnMainQueue
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = WhitegramHistoryPresentation(presentationData)
        let title = showsChats ? strings.text("Archived chats", "Чаты в архиве") : strings.text("Message history", "История сообщений")
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: historyRows(coordinator, strings: strings), style: .blocks, animateChanges: false), actions))
    }
    let controller = ItemListController(context: context, state: signal)
    coordinator.controller = controller
    return controller
}

public func whitegramHistoryController(context: AccountContext, scope: WhitegramHistoryScope = .account, event: WhitegramHistoryEvent? = nil) -> ViewController {
    let order: WhitegramHistoryOrder
    if case .message = scope { order = .captureTime } else { order = .originalTime }
    return whitegramHistoryListController(context: context, query: WhitegramHistoryQuery(scope: scope, event: event, order: order), showsChats: false)
}

public func whitegramMessageHistoryController(context: AccountContext, messageId: EngineMessage.Id) -> ViewController {
    return whitegramHistoryController(context: context, scope: .message(WhitegramHistoryMessageId(peerId: String(messageId.peerId.toInt64()), namespace: messageId.namespace, id: messageId.id)))
}
