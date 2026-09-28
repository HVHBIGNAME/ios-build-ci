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
    weak var controller: ViewController?
    var records: [WhitegramHistoryEntry] = []
    var status: String = ""
    var filter: WhitegramHistoryEvent?
    var query = ""
    var limit = 100
    private var generation = 0
    private var observer: NSObjectProtocol?

    init(context: AccountContext) {
        self.context = context
        self.store = WhitegramHistoryStore.forAccount(mediaBoxPath: context.account.postbox.mediaBox.basePath, accountPeerId: context.account.peerId)
        super.init()
        self.observer = NotificationCenter.default.addObserver(forName: WhitegramHistoryStore.updatedNotification, object: self.store, queue: .main) { [weak self] _ in self?.reload() }
        self.reload()
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func changed() { self.generation += 1; self.revision.set(self.generation) }

    func reload() {
        self.store.snapshot { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(entries): self.records = entries; self.status = "\(entries.count) / 2000"
            case let .failure(error): self.status = error.localizedDescription
            }
            self.changed()
        }
    }

    func toggle(_ key: String, _ value: Bool) {
        if !WhitegramPreferences.set(value, for: key) { self.status = "Could not save setting." }
        self.changed()
    }

    func action(_ id: String) {
        guard let controller else { return }
        switch id {
        case "export":
            self.store.export { [weak self] result in
                guard let self, let controller = self.controller else { return }
                do {
                    let data = try result.get()
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Whitegram-History-\(UUID().uuidString).json")
                    try data.write(to: url, options: .atomic)
                    let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    share.popoverPresentationController?.sourceView = controller.view
                    share.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
                    share.completionWithItemsHandler = { _, _, _, _ in
                        do { try FileManager.default.removeItem(at: url) }
                        catch { NSLog("Whitegram: history export cleanup failed") }
                    }
                    controller.present(share, animated: true)
                } catch { self.status = error.localizedDescription; self.changed() }
            }
        case "import":
            let picker = UIDocumentPickerViewController(documentTypes: ["public.json"], in: .import)
            picker.delegate = self
            controller.present(picker, animated: true)
        case "clear":
            let alert = UIAlertController(title: "Clear local archive?", message: "This removes the displayed archive category from this device. Telegram messages are not deleted.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Clear", style: .destructive, handler: { [weak self] _ in
                guard let self else { return }
                self.store.clear(event: self.filter) { [weak self] result in
                    if case let .failure(error) = result { self?.status = error.localizedDescription; self?.changed() }
                    else { self?.reload() }
                }
            }))
            controller.present(alert, animated: true)
        case "filter":
            let sheet = UIAlertController(title: "Archive", message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "All", style: .default, handler: { [weak self] _ in self?.filter = nil; self?.changed() }))
            for event in WhitegramHistoryEvent.allCases {
                sheet.addAction(UIAlertAction(title: event.rawValue, style: .default, handler: { [weak self] _ in self?.filter = event; self?.changed() }))
            }
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            sheet.popoverPresentationController?.sourceView = controller.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
            controller.present(sheet, animated: true)
        case "search":
            let alert = UIAlertController(title: "Search archive", message: nil, preferredStyle: .alert)
            alert.addTextField { $0.text = self.query }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Search", style: .default, handler: { [weak self, weak alert] _ in
                self?.query = alert?.textFields?.first?.text ?? ""
                self?.limit = 100
                self?.changed()
            }))
            controller.present(alert, animated: true)
        case "more": self.limit += 100; self.changed()
        default:
            guard let entry = self.records.first(where: { $0.key == id }) else { return }
            let screen = whitegramSimpleInfoController(context: self.context, title: entry.event.rawValue, lines: [
                "Peer: \(entry.peerId) · Message: \(entry.messageId)", "Author: \(entry.authorId ?? "—")",
                Date(timeIntervalSince1970: Double(entry.messageDate)).description,
                entry.text, entry.mediaCount == 0 ? "" : "\(entry.mediaCount) media attachment(s); media bytes are not in the text archive."
            ])
            controller.navigationController?.pushViewController(screen, animated: true)
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
                    switch result {
                    case .success: self?.reload()
                    case let .failure(error): self?.status = error.localizedDescription; self?.changed()
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.status = error.localizedDescription; self?.changed() }
            }
        }
    }
}

private struct WhitegramHistoryRow: ItemListNodeEntry {
    let id: String
    let index: Int
    let title: String
    let detail: String
    let value: Bool?
    let isInfo: Bool

    var section: ItemListSectionId { return self.index < 20 ? 0 : 1 }
    var stableId: String { return self.id }
    static func ==(lhs: Self, rhs: Self) -> Bool { return lhs.id == rhs.id && lhs.title == rhs.title && lhs.detail == rhs.detail && lhs.value == rhs.value }
    static func <(lhs: Self, rhs: Self) -> Bool { return lhs.index < rhs.index }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let coordinator = arguments as! WhitegramHistoryCoordinator
        if let value {
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: self.title, value: value, sectionId: self.section, style: .blocks, updated: { coordinator.toggle(self.id, $0) })
        } else if self.isInfo {
            return ItemListTextItem(presentationData: presentationData, text: .plain(self.title), sectionId: self.section, style: .blocks)
        } else {
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: self.title, label: self.detail, sectionId: self.section, style: .blocks, action: { coordinator.action(self.id) })
        }
    }
}

public func whitegramHistoryController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramHistoryCoordinator(context: context)
    let signal = combineLatest(context.sharedContext.presentationData, coordinator.revision.get())
    |> deliverOnMainQueue
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let ru = presentationData.strings.baseLanguageCode.hasPrefix("ru")
        var rows: [WhitegramHistoryRow] = []
        let switches = [
            ("showDeletedMessages", "Сохранять удалённые сообщения", "Save deleted messages"),
            ("showEditedOriginalText", "Сохранять текст до изменения", "Save edited originals"),
            ("saveChatHistory", "Сохранять полученные сообщения", "Save received messages"),
            ("hideMyDeletedMessages", "Не сохранять мои удалённые", "Exclude own deleted messages"),
            ("hideMyEditedMessages", "Не сохранять мои изменения", "Exclude own edited messages"),
            ("hideBotDeletedMessages", "Не сохранять удалённые у ботов", "Exclude bot deletions"),
            ("hideBotEditedMessages", "Не сохранять изменения у ботов", "Exclude bot edits")
        ]
        for (index, value) in switches.enumerated() {
            rows.append(WhitegramHistoryRow(id: value.0, index: index, title: ru ? value.1 : value.2, detail: "", value: WhitegramPreferences.bool(value.0), isInfo: false))
        }
        for (id, title) in [("filter", ru ? "Фильтр" : "Filter"), ("search", ru ? "Поиск" : "Search"), ("export", ru ? "Экспорт JSON" : "Export JSON"), ("import", ru ? "Импорт JSON" : "Import JSON"), ("clear", ru ? "Очистить архив" : "Clear archive")] {
            rows.append(WhitegramHistoryRow(id: id, index: rows.count, title: title, detail: "", value: nil, isInfo: false))
        }
        rows.append(WhitegramHistoryRow(id: "status", index: rows.count, title: coordinator.status, detail: "", value: nil, isInfo: true))
        rows.append(WhitegramHistoryRow(id: "scope", index: rows.count, title: ru ? "Локальный архив текста уже полученных облачных сообщений. Медиа и секретные чаты не сохраняются. До включения история не восстанавливается." : "Local text archive of cloud messages already received. Media and secret chats are not saved. Earlier history is not reconstructed.", detail: "", value: nil, isInfo: true))
        let entries = coordinator.records.filter { entry in
            return (coordinator.filter == nil || entry.event == coordinator.filter) && (coordinator.query.isEmpty || entry.text.localizedCaseInsensitiveContains(coordinator.query) || entry.peerId.contains(coordinator.query))
        }
        for (index, entry) in entries.prefix(coordinator.limit).enumerated() {
            rows.append(WhitegramHistoryRow(id: entry.key, index: 20 + index, title: entry.text.isEmpty ? "[media]" : String(entry.text.prefix(100)), detail: "\(entry.event.rawValue) · \(entry.peerId)", value: nil, isInfo: false))
        }
        if entries.count > coordinator.limit { rows.append(WhitegramHistoryRow(id: "more", index: 20 + coordinator.limit, title: ru ? "Показать ещё" : "Show more", detail: "", value: nil, isInfo: false)) }
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(ru ? "История сообщений" : "Message history"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: rows, style: .blocks, animateChanges: false), coordinator))
    }
    let controller = ItemListController(context: context, state: signal)
    coordinator.controller = controller
    return controller
}
