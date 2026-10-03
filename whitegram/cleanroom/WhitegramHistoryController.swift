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
    private let operation = MetaDisposable()
    private var operationInProgress = false

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

    deinit {
        self.operation.dispose()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
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
        if let peerId = self.query.scope.peerId, let rawId = Int64(peerId), key == "perChatHideDeleted" || key == "perChatHideEdited" {
            var ids = WhitegramHistoryPolicy.parsePeerIds(WhitegramPreferences.string(key, default: UserDefaults.standard.string(forKey: "wg_" + key) ?? ""))
            if value { ids.insert(rawId) } else { ids.remove(rawId) }
            self.status = WhitegramPreferences.set(ids.sorted().map(String.init).joined(separator: ","), for: key) ? "" : self.strings.text("Could not save setting.", "Не удалось сохранить настройку.")
            self.changed()
            return
        }
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

    private func opacity() {
        let strings = self.strings
        let alert = UIAlertController(title: strings.text("Deleted message opacity", "Непрозрачность удалённых сообщений"), message: strings.text("1–100%. Original default: 45%.", "1–100%. Исходное значение: 45%."), preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = .decimalPad
            field.text = String(Int((WhitegramHistoryRuntime.policy.deletedOpacity * 100.0).rounded()))
        }
        alert.addAction(UIAlertAction(title: strings.text("Cancel", "Отмена"), style: .cancel))
        alert.addAction(UIAlertAction(title: strings.text("Save", "Сохранить"), style: .default, handler: { [weak self, weak alert] _ in
            guard let self else { return }
            guard let number = Double((alert?.textFields?.first?.text ?? "").replacingOccurrences(of: ",", with: ".")), number.isFinite, (1.0...100.0).contains(number) else {
                self.status = strings.text("Enter a number from 1 to 100.", "Введите число от 1 до 100.")
                self.changed()
                return
            }
            self.status = WhitegramPreferences.set(number / 100.0, for: "deletedMessagesOpacity") ? "" : strings.text("Could not save setting.", "Не удалось сохранить настройку.")
            self.changed()
        }))
        self.controller?.present(alert, animated: true)
    }

    private func nativeAction(_ action: WhitegramHistoryAction) {
        guard !self.operationInProgress else { return }
        let scope = self.query.scope
        if action == .restoreChatsView && scope == .account {
            self.controller?.navigationController?.pushViewController(whitegramHistoryRestorableChatsController(context: self.context), animated: true)
            return
        }
        self.store.snapshot { [weak self] snapshot in
            guard let self, let controller = self.controller else { return }
            let records: [WhitegramHistoryEntry]
            switch snapshot {
            case let .success(value): records = value
            case let .failure(error): self.status = error.localizedDescription; self.changed(); return
            }
            let strings = self.strings
            let title = strings.action(action)
            let scopeTitle = scope.peerId.map { " [\($0)]" } ?? strings.text(" in this account", " в этом аккаунте")
            let alert = UIAlertController(title: title + scopeTitle, message: strings.actionDescription(action), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: strings.text("Cancel", "Отмена"), style: .cancel))
            alert.addAction(UIAlertAction(title: title, style: action == .restoreChatsView ? .default : .destructive, handler: { [weak self] _ in
                guard let self else { return }
                self.operationInProgress = true
                self.status = strings.text("Updating local history…", "Обновление локальной истории…")
                self.changed()
                self.operation.set((WhitegramHistoryOperations.perform(postbox: self.context.account.postbox, accountPeerId: self.context.account.peerId, action: action, scope: scope, records: records)
                |> deliverOnMainQueue).start(next: { [weak self] result in
                    guard let self else { return }
                    self.operationInProgress = false
                    switch result {
                    case let .failure(error): self.status = error.localizedDescription; self.changed()
                    case let .success(result):
                        let summary = strings.operationResult(result)
                        let archiveEvent: WhitegramHistoryEvent?
                        switch action {
                        case .clearEditedCache: archiveEvent = .edited
                        case .clearSavedChatHistory: archiveEvent = .received
                        default: archiveEvent = nil
                        }
                        if let archiveEvent, !result.cancelled {
                            self.store.clear(matching: WhitegramHistoryQuery(scope: scope, event: archiveEvent)) { [weak self] cleared in
                                guard let self else { return }
                                switch cleared {
                                case .success: self.status = summary; self.reload()
                                case let .failure(error):
                                    self.status = summary + "\n" + strings.text("The native cache was updated, but the archive could not be cleared: ", "Нативный кеш обновлён, но архив не удалось очистить: ") + error.localizedDescription
                                    self.changed()
                                }
                            }
                        } else { self.status = summary; self.reload() }
                    }
                }))
            }))
            controller.present(alert, animated: true)
        }
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

    private func export(deletedOnly: Bool = false) {
        var query = self.query
        if deletedOnly { query.event = .deleted; query.text = "" }
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
        case "exportDeletedBackup": self.export(deletedOnly: true)
        case "opacity": self.opacity()
        case "nativeChats", "restoreChatsView": self.nativeAction(.restoreChatsView)
        case "clearDeletedCache": self.nativeAction(.clearDeletedCache)
        case "clearEditedCache": self.nativeAction(.clearEditedCache)
        case "clearSavedChatHistory": self.nativeAction(.clearSavedChatHistory)
        case "import", "importDeletedBackup":
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
                if data.count <= WhitegramHistoryStore.maximumArchiveBytes, try JSONSerialization.jsonObject(with: data) is [Any] {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let controller = self.controller else { return }
                        let strings = self.strings
                        let accountId = String(self.context.account.peerId.toInt64())
                        let alert = UIAlertController(title: strings.text("Import original Whitegram backup?", "Импортировать резервную копию Whitegram?"), message: strings.text("This original-format file does not identify its account. Import it as a text backup for account \(accountId)? Existing messages will not be overwritten. Restoration is a separate local action.", "В исходном формате не указан аккаунт. Импортировать текстовую копию для аккаунта \(accountId)? Существующие сообщения не будут перезаписаны. Локальное восстановление выполняется отдельно."), preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: strings.text("Cancel", "Отмена"), style: .cancel))
                        alert.addAction(UIAlertAction(title: strings.text("Import for this account", "Импортировать для этого аккаунта"), style: .default, handler: { [weak self] _ in
                            self?.store.importOriginalBackupForThisAccount(data) { [weak self] result in self?.imported(result) }
                        }))
                        controller.present(alert, animated: true)
                    }
                } else {
                    self?.store.importArchive(data) { [weak self] result in self?.imported(result) }
                }
            } catch {
                DispatchQueue.main.async { self?.status = error.localizedDescription; self?.changed() }
            }
        }
    }

    private func imported(_ result: Result<Int, Error>) {
        switch result {
        case let .success(count): self.status = self.strings.text("Added \(count) new versions to this account's archive.", "В архив этого аккаунта добавлено новых версий: \(count)."); self.reload()
        case let .failure(error): self.status = error.localizedDescription; self.changed()
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
            ("showDeletedMessages", "Show deleted messages in chats", "Показывать удалённые сообщения"),
            ("showEditedOriginalText", "Show original text and save edits", "Показывать исходный текст и сохранять изменения"),
            ("saveChatHistory", "Save received messages", "Сохранять полученные сообщения"),
            ("saveDeletedMessagesToBackup", "Back up deleted message text", "Резервная копия текста удалённых сообщений"),
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
        action("opacity", strings.text("Deleted message opacity", "Непрозрачность удалённых"), detail: "\(Int((WhitegramHistoryRuntime.policy.deletedOpacity * 100).rounded()))%")
    } else {
        action("settings", strings.text("Archive & capture settings", "Архив и настройки сохранения"))
    }
    if let peerId = coordinator.query.scope.peerId {
        let title = coordinator.records.first(where: { $0.peerId == peerId && $0.peerTitle != nil })?.peerTitle ?? peerId
        rows.append(WhitegramHistoryRow(id: "scope", index: rows.count, section: 1, title: "\(title) [\(peerId)]", isInfo: true))
        if let rawId = Int64(peerId) {
            let policy = WhitegramHistoryRuntime.policy
            rows.append(WhitegramHistoryRow(id: "perChatHideDeleted", index: rows.count, section: 0, title: strings.text("Hide deleted messages in this chat", "Скрывать удалённые в этом чате"), value: policy.hiddenDeletedPeers.contains(rawId)))
            rows.append(WhitegramHistoryRow(id: "perChatHideEdited", index: rows.count, section: 0, title: strings.text("Hide original text in this chat", "Скрывать исходный текст в этом чате"), value: policy.hiddenEditedPeers.contains(rawId)))
        }
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
        for operation in WhitegramHistoryAction.allCases where operation != .importDeletedBackup || coordinator.query.scope == .account {
            action(operation.rawValue, strings.action(operation))
        }
        action("export", strings.text("Export matching versions", "Экспорт найденных версий"))
        action("clear", strings.text("Clear matching versions", "Удалить найденные версии"))
    }
    let entries = coordinator.matchingEntries
    let status = coordinator.loadError ?? strings.text("\(entries.count) matching versions · \(coordinator.records.count) / \(WhitegramHistoryStore.maximumEntries) in this account", "Найдено версий: \(entries.count) · В аккаунте: \(coordinator.records.count) / \(WhitegramHistoryStore.maximumEntries)")
    rows.append(WhitegramHistoryRow(id: "status", index: rows.count, section: 1, title: status, isInfo: true))
    if !coordinator.status.isEmpty {
        rows.append(WhitegramHistoryRow(id: "operation", index: rows.count, section: 1, title: coordinator.status, isInfo: true))
    }
    rows.append(WhitegramHistoryRow(id: "limits", index: rows.count, section: 1, title: strings.text("Deleted messages retained in a chat keep their native attachments and formatting. JSON backups contain text and attachment metadata, not media files. Already downloaded content can be restored locally; missing content cannot be fetched from this archive. Secret chats are excluded.", "Удалённые сообщения, сохранённые в чате, сохраняют нативные вложения и форматирование. JSON-копии содержат текст и метаданные, но не медиафайлы. Уже полученное содержимое можно восстановить локально; отсутствующее содержимое архив не загружает. Секретные чаты исключены."), isInfo: true))
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

private func whitegramHistoryListController(context: AccountContext, query: WhitegramHistoryQuery, showsChats: Bool, initialAction: WhitegramHistoryAction? = nil) -> ViewController {
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
    if let initialAction {
        controller.didAppear = { firstTime in
            if firstTime { coordinator.action(initialAction.rawValue) }
        }
    }
    return controller
}

public func whitegramHistoryController(context: AccountContext, scope: WhitegramHistoryScope = .account, event: WhitegramHistoryEvent? = nil) -> ViewController {
    let order: WhitegramHistoryOrder
    if case .message = scope { order = .captureTime } else { order = .originalTime }
    return whitegramHistoryListController(context: context, query: WhitegramHistoryQuery(scope: scope, event: event, order: order), showsChats: false)
}

public func whitegramMessageHistoryController(context: AccountContext, messageId: EngineMessage.Id) -> ViewController {
    return whitegramNativeMessageHistoryController(context: context, messageId: messageId)
}

public func whitegramHistoryActionController(context: AccountContext, action: WhitegramHistoryAction, scope: WhitegramHistoryScope = .account) -> ViewController {
    return whitegramHistoryListController(context: context, query: WhitegramHistoryQuery(scope: scope), showsChats: false, initialAction: action)
}
