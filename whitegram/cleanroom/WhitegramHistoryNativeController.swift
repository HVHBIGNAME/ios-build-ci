import Foundation
import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext
import TextFormat

private final class WhitegramHistoryTextController: ViewController {
    private let textView = UITextView()
    private let value: String
    private let attributedValue: NSAttributedString
    private let background: UIColor

    init(context: AccountContext, title: String, text: String, entities: [MessageTextEntity], message: EngineRawMessage) {
        let presentation = context.sharedContext.currentPresentationData.with { $0 }
        let font = UIFont.systemFont(ofSize: 17)
        self.value = text
        self.background = presentation.theme.list.blocksBackgroundColor
        let validEntities = entities.filter { $0.range.lowerBound >= 0 && $0.range.upperBound <= text.utf16.count }
        self.attributedValue = stringWithAppliedEntities(text, entities: validEntities, strings: presentation.strings,
            dateTimeFormat: presentation.dateTimeFormat, baseColor: presentation.theme.list.itemPrimaryTextColor,
            linkColor: presentation.theme.list.itemAccentColor, baseFont: font, linkFont: font,
            boldFont: UIFont.boldSystemFont(ofSize: 17), italicFont: UIFont.italicSystemFont(ofSize: 17),
            boldItalicFont: UIFont(descriptor: font.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) ?? font.fontDescriptor, size: 17),
            fixedFont: UIFont(name: "Menlo", size: 16) ?? font, blockQuoteFont: font, message: message)
        super.init(navigationBarPresentationData: NavigationBarPresentationData(presentationData: presentation))
        self.title = title
        let strings = WhitegramHistoryPresentation(presentation)
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(title: strings.text("Copy", "Копировать"), style: .plain, target: self, action: #selector(self.copyText))
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func copyText() { UIPasteboard.general.string = self.value }

    override func loadDisplayNode() {
        self.displayNode = ASDisplayNode()
        self.displayNode.backgroundColor = self.background
        self.textView.isEditable = false
        self.textView.isSelectable = true
        self.textView.alwaysBounceVertical = true
        self.textView.backgroundColor = self.background
        self.textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        self.textView.attributedText = self.attributedValue
        self.displayNode.view.addSubview(self.textView)
        self.displayNodeDidLoad()
    }

    override func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        let top = self.navigationLayout(layout: layout).navigationFrame.maxY
        self.textView.frame = CGRect(x: layout.safeInsets.left, y: top, width: layout.size.width - layout.safeInsets.left - layout.safeInsets.right, height: max(0, layout.size.height - top - layout.intrinsicInsets.bottom))
    }
}

private final class WhitegramNativeMessageHistoryState {
    let context: AccountContext
    let messageId: EngineMessage.Id
    let revision = ValuePromise<Int>(0, ignoreRepeated: true)
    weak var controller: ViewController?
    var message: EngineRawMessage?
    var error: String?
    var loaded = false
    private var generation = 0
    private let disposable = MetaDisposable()

    init(context: AccountContext, messageId: EngineMessage.Id) {
        self.context = context
        self.messageId = messageId
    }

    deinit { self.disposable.dispose() }

    var scope: WhitegramHistoryScope {
        return .message(WhitegramHistoryMessageId(peerId: String(self.messageId.peerId.toInt64()), namespace: self.messageId.namespace, id: self.messageId.id))
    }

    func reload() {
        self.disposable.set((WhitegramHistoryOperations.message(postbox: self.context.account.postbox, accountPeerId: self.context.account.peerId, id: self.messageId)
        |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self else { return }
            self.loaded = true
            switch result {
            case let .success(message): self.message = message; self.error = nil
            case let .failure(error): self.message = nil; self.error = error.localizedDescription
            }
            self.generation += 1
            self.revision.set(self.generation)
        }))
    }

    func select(_ id: String) {
        guard let controller else { return }
        switch id {
        case "archive": controller.navigationController?.pushViewController(whitegramHistoryController(context: self.context, scope: self.scope), animated: true)
        case "restore": controller.navigationController?.pushViewController(whitegramHistoryActionController(context: self.context, action: .restoreChatsView, scope: self.scope), animated: true)
        case "clear-edits": controller.navigationController?.pushViewController(whitegramHistoryActionController(context: self.context, action: .clearEditedCache, scope: self.scope), animated: true)
        case "reload": self.reload()
        default:
            guard let message = self.message else { return }
            let presentation = self.context.sharedContext.currentPresentationData.with { $0 }
            let strings = WhitegramHistoryPresentation(presentation)
            let text: String
            let entities: [MessageTextEntity]
            let title: String
            if id == "current" {
                text = message.text
                entities = message.textEntitiesAttribute?.entities ?? []
                title = strings.text("Retained message text", "Сохранённый текст сообщения")
            } else if id.hasPrefix("edit:"), let index = Int(id.dropFirst(5)), let edits = message.whitegramHistoryAttribute?.edits, edits.indices.contains(index) {
                text = edits[index].text
                entities = edits[index].entities
                title = strings.date(Double(edits[index].date))
            } else { return }
            controller.navigationController?.pushViewController(WhitegramHistoryTextController(context: self.context, title: title, text: text, entities: entities, message: message), animated: true)
        }
    }
}

private func nativeMessageRows(_ state: WhitegramNativeMessageHistoryState, strings: WhitegramHistoryPresentation) -> [WhitegramHistoryRow] {
    var rows: [WhitegramHistoryRow] = []
    func row(_ id: String, _ title: String, detail: String = "", info: Bool = false, section: ItemListSectionId = 0) {
        rows.append(WhitegramHistoryRow(id: id, index: rows.count, section: section, title: title, detail: detail, isInfo: info))
    }
    row("identity", "\(state.messageId.peerId.toInt64()) · \(state.messageId.namespace):\(state.messageId.id)", info: true)
    if let error = state.error { row("error", error, info: true) }
    else if !state.loaded { row("loading", strings.text("Loading local history…", "Загрузка локальной истории…"), info: true) }
    else if let message = state.message {
        let attribute = message.whitegramHistoryAttribute
        row("date", strings.text("Sent: ", "Отправлено: ") + strings.date(Double(message.timestamp)), info: true)
        if attribute?.isDeleted == true {
            row("deleted", strings.text("Deleted on Telegram; retained on this device.", "Удалено в Telegram; сохранено на этом устройстве."), info: true)
            if let deletedAt = attribute?.deletedAt { row("deleted-at", strings.text("Observed deletion: ", "Удаление получено: ") + strings.date(Double(deletedAt)), info: true) }
        } else if attribute?.isLocallyRestored == true {
            row("restored", strings.text("Local restored copy. It has not been resent to Telegram.", "Локальная восстановленная копия. Повторно в Telegram не отправлялась."), info: true)
        }
        if !message.text.isEmpty { row("current", strings.text("Open full message text", "Открыть полный текст"), detail: String(message.text.prefix(100)), section: 1) }
        if !message.media.isEmpty {
            row("media", strings.text("Native attachments: \(message.media.count). Open the retained bubble in the chat to view downloaded media. Media remains subject to Telegram's cache settings.", "Нативных вложений: \(message.media.count). Откройте сохранённое сообщение в чате для просмотра загруженного медиа. Действуют настройки кеша Telegram."), info: true, section: 1)
        }
        let edits = attribute?.edits ?? []
        for index in edits.indices.reversed() {
            row("edit:\(index)", strings.text("Version before edit \(index + 1)", "Версия до изменения \(index + 1)"), detail: strings.date(Double(edits[index].date)) + "\n" + String(edits[index].text.prefix(100)), section: 2)
        }
        if edits.isEmpty { row("no-edits", strings.text("No earlier native text versions were observed on this device.", "Ранее полученных нативных версий текста на этом устройстве нет."), info: true, section: 2) }
        if !edits.isEmpty { row("clear-edits", strings.action(.clearEditedCache), section: 3) }
        if attribute?.isDeleted == true { row("restore", strings.action(.restoreChatsView), section: 3) }
    } else {
        row("missing", strings.text("The native message is no longer stored. Check this message's separate archive for locally received copies.", "Нативное сообщение больше не хранится. Проверьте отдельный архив этого сообщения."), info: true)
        row("restore", strings.action(.restoreChatsView), section: 3)
    }
    row("archive", strings.text("Open separate archive & backup", "Открыть отдельный архив и копии"), section: 3)
    row("reload", strings.text("Refresh", "Обновить"), section: 3)
    return rows
}

public func whitegramNativeMessageHistoryController(context: AccountContext, messageId: EngineMessage.Id) -> ViewController {
    let state = WhitegramNativeMessageHistoryState(context: context, messageId: messageId)
    let actions = WhitegramHistoryListActions(select: { state.select($0) })
    let signal = combineLatest(context.sharedContext.presentationData, state.revision.get())
    |> deliverOnMainQueue
    |> map { presentation, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = WhitegramHistoryPresentation(presentation)
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentation), title: .text(strings.text("Message history", "История сообщения")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentation.strings.Common_Back), animateChanges: false)
        return (controllerState, (ItemListNodeState(presentationData: ItemListPresentationData(presentation), entries: nativeMessageRows(state, strings: strings), style: .blocks, animateChanges: false), actions))
    }
    let controller = ItemListController(context: context, state: signal)
    state.controller = controller
    controller.didAppear = { _ in state.reload() }
    return controller
}

private final class WhitegramRestorableChatsState {
    let context: AccountContext
    let revision = ValuePromise<Int>(0, ignoreRepeated: true)
    weak var controller: ViewController?
    var chats: [WhitegramHistoryChatSummary] = []
    var error: String?
    var loaded = false
    private var generation = 0
    private let disposable = MetaDisposable()

    init(context: AccountContext) { self.context = context }
    deinit { self.disposable.dispose() }

    func reload() {
        self.generation += 1
        let generation = self.generation
        let store = WhitegramHistoryStore.forAccount(mediaBoxPath: self.context.account.postbox.mediaBox.basePath, accountPeerId: self.context.account.peerId)
        store.snapshot { [weak self] result in
            guard let self, self.generation == generation else { return }
            switch result {
            case let .failure(error): self.error = error.localizedDescription; self.loaded = true; self.revision.set(generation)
            case let .success(records):
                self.disposable.set((WhitegramHistoryOperations.chats(postbox: self.context.account.postbox, accountPeerId: self.context.account.peerId, records: records)
                |> deliverOnMainQueue).start(next: { [weak self] result in
                    guard let self, self.generation == generation else { return }
                    switch result {
                    case let .failure(error): self.error = error.localizedDescription
                    case let .success(chats): self.chats = chats; self.error = nil
                    }
                    self.loaded = true
                    self.revision.set(generation)
                }))
            }
        }
    }

    func select(_ id: String) {
        if id == "reload" { self.reload(); return }
        guard self.chats.contains(where: { $0.peerId == id }) else { return }
        self.controller?.navigationController?.pushViewController(whitegramHistoryActionController(context: self.context, action: .restoreChatsView, scope: .peer(id)), animated: true)
    }
}

public func whitegramHistoryRestorableChatsController(context: AccountContext) -> ViewController {
    let state = WhitegramRestorableChatsState(context: context)
    let actions = WhitegramHistoryListActions(select: { state.select($0) })
    let signal = combineLatest(context.sharedContext.presentationData, state.revision.get())
    |> deliverOnMainQueue
    |> map { presentation, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = WhitegramHistoryPresentation(presentation)
        var rows: [WhitegramHistoryRow] = []
        let explanation = state.error ?? (state.loaded ? strings.text("Select a chat to restore locally retained messages and available text backups.", "Выберите чат для локального восстановления сохранённых сообщений и доступных текстовых копий.") : strings.text("Reading local histories…", "Чтение локальной истории…"))
        rows.append(WhitegramHistoryRow(id: "info", index: 0, section: 0, title: explanation, isInfo: true))
        for chat in state.chats {
            let detail = "\(chat.peerId) · " + strings.text("deleted: \(chat.deletedCount), edited: \(chat.editedCount), backups: \(chat.backupCount)", "удалённых: \(chat.deletedCount), изменённых: \(chat.editedCount), копий: \(chat.backupCount)")
            rows.append(WhitegramHistoryRow(id: chat.peerId, index: rows.count, section: 1, title: chat.title, detail: detail))
        }
        if state.loaded && state.error == nil && state.chats.isEmpty { rows.append(WhitegramHistoryRow(id: "empty", index: rows.count, section: 1, title: strings.text("No retained chat history is available for this account.", "Для этого аккаунта нет сохранённой истории."), isInfo: true)) }
        rows.append(WhitegramHistoryRow(id: "reload", index: rows.count, section: 2, title: strings.text("Refresh", "Обновить")))
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentation), title: .text(strings.text("Restore chats", "Восстановить чаты")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentation.strings.Common_Back), animateChanges: false)
        return (controllerState, (ItemListNodeState(presentationData: ItemListPresentationData(presentation), entries: rows, style: .blocks, animateChanges: false), actions))
    }
    let controller = ItemListController(context: context, state: signal)
    state.controller = controller
    controller.didAppear = { _ in state.reload() }
    return controller
}
