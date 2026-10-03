import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext

struct WhitegramHistoryPresentation {
    let russian: Bool
    private let dateFormatter: DateFormatter

    init(_ presentationData: PresentationData) {
        self.russian = presentationData.strings.baseLanguageCode.hasPrefix("ru")
        self.dateFormatter = DateFormatter()
        self.dateFormatter.locale = Locale(identifier: presentationData.strings.baseLanguageCode)
        self.dateFormatter.timeZone = .autoupdatingCurrent
        self.dateFormatter.dateStyle = .medium
        self.dateFormatter.timeStyle = .medium
    }

    func text(_ english: String, _ russian: String) -> String { return self.russian ? russian : english }
    func date(_ timestamp: Double) -> String { return self.dateFormatter.string(from: Date(timeIntervalSince1970: timestamp)) }

    func event(_ event: WhitegramHistoryEvent?) -> String {
        switch event {
        case .received?: return self.text("Received", "Полученные")
        case .deleted?: return self.text("Deleted", "Удалённые")
        case .edited?: return self.text("Before edit", "До изменения")
        case nil: return self.text("All versions", "Все версии")
        }
    }

    func order(_ order: WhitegramHistoryOrder) -> String {
        return order == .originalTime ? self.text("Original message time", "Исходное время сообщения") : self.text("Archive capture time", "Время сохранения в архив")
    }

    func action(_ action: WhitegramHistoryAction) -> String {
        switch action {
        case .clearDeletedCache: return self.text("Clear deletion markers", "Очистить кеш удалённых")
        case .clearEditedCache: return self.text("Clear edit history", "Очистить кеш изменений")
        case .clearSavedChatHistory: return self.text("Clear saved history", "Очистить сохранённую историю")
        case .restoreChatsView: return self.text("Restore local chat history", "Восстановить историю чата локально")
        case .exportDeletedBackup: return self.text("Export deleted-message backup", "Экспорт копии удалённых сообщений")
        case .importDeletedBackup: return self.text("Import deleted-message backup", "Импорт копии удалённых сообщений")
        }
    }

    func actionDescription(_ action: WhitegramHistoryAction) -> String {
        switch action {
        case .clearDeletedCache: return self.text("Reset deletion markers in this scope. The retained message text and native media remain as local copies. The separate JSON backup is kept.", "Снять метки удаления в выбранной области. Сохранённые сообщения и нативные вложения останутся локальными копиями. Отдельная JSON-копия сохраняется.")
        case .clearEditedCache: return self.text("Erase saved original text, entities and edit versions in this scope, including the separate edit archive. Current message content stays intact.", "Удалить сохранённые исходные тексты, форматирование и версии изменений в выбранной области, включая отдельный архив изменений. Текущее содержимое сообщений сохраняется.")
        case .clearSavedChatHistory: return self.text("Clear received-message archive copies in this scope and reset deletion markers for those saved messages. Separate deleted-message backups are kept.", "Очистить архив полученных сообщений в выбранной области и снять метки удаления с этих сохранённых сообщений. Отдельные копии удалённых сообщений сохраняются.")
        case .restoreChatsView: return self.text("Restore retained messages and create missing text copies from this account's archive, using their original message IDs and times. This only changes local history. Live messages are never overwritten. JSON does not contain media files; unavailable, media-only and truncated copies will be reported.", "Восстановить сохранённые сообщения и недостающие текстовые копии из архива этого аккаунта с исходными ID и временем. Изменится только локальная история. Существующие сообщения не перезаписываются. JSON не содержит медиафайлов; недоступные, обрезанные и нетекстовые копии будут указаны в результате.")
        case .exportDeletedBackup, .importDeletedBackup: return self.text("Account-scoped local text backup.", "Локальная текстовая копия этого аккаунта.")
        }
    }

    func operationResult(_ result: WhitegramHistoryOperationResult) -> String {
        return self.text("Reset markers: \(result.restoredMarkers). Cleared edits: \(result.clearedEdits). Created text copies: \(result.createdTextCopies). Kept live: \(result.skippedLive). Already restored: \(result.skippedExisting). Unavailable: \(result.skippedUnavailable). Copies without media: \(result.copiesWithoutMedia).", "Снято меток: \(result.restoredMarkers). Удалено версий изменений: \(result.clearedEdits). Создано текстовых копий: \(result.createdTextCopies). Существующих сообщений: \(result.skippedLive). Уже восстановлено: \(result.skippedExisting). Недоступно: \(result.skippedUnavailable). Копий без медиа: \(result.copiesWithoutMedia).") + (result.cancelled ? self.text(" Cancelled; completed local changes were retained.", " Отменено; выполненные локальные изменения сохранены.") : "")
    }

    func mediaKind(_ kind: WhitegramHistoryMedia.Kind) -> String {
        switch kind {
        case .photo: return self.text("Photo", "Фото")
        case .video: return self.text("Video", "Видео")
        case .videoMessage: return self.text("Video message", "Видеосообщение")
        case .audio: return self.text("Audio", "Аудио")
        case .voice: return self.text("Voice message", "Голосовое сообщение")
        case .sticker: return self.text("Sticker", "Стикер")
        case .file: return self.text("File", "Файл")
        case .webpage: return self.text("Link preview", "Предпросмотр ссылки")
        case .poll: return self.text("Poll", "Опрос")
        case .other: return self.text("Other attachment", "Другое вложение")
        }
    }

    func summary(_ entry: WhitegramHistoryEntry) -> String {
        if !entry.text.isEmpty {
            return String(entry.text.replacingOccurrences(of: "\n", with: " ").prefix(100))
        }
        if let media = entry.media, !media.isEmpty {
            return String(media.map { $0.fileName ?? self.mediaKind($0.kind) }.joined(separator: ", ").prefix(100))
        }
        return entry.mediaCount == 0 ? self.text("Empty message", "Пустое сообщение") : self.text("Attachment", "Вложение")
    }

    func metadata(_ media: WhitegramHistoryMedia) -> String {
        var lines = [self.mediaKind(media.kind)]
        if let name = media.fileName { lines.append(name) }
        if let mime = media.mimeType { lines.append(mime) }
        if let size = media.size { lines.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let width = media.width, let height = media.height { lines.append("\(width) × \(height)") }
        if let duration = media.duration { lines.append(String(format: "%.1f s", duration)) }
        if let id = media.mediaId { lines.append("Media ID: \(id)") }
        return lines.joined(separator: " · ")
    }
}

final class WhitegramHistoryListActions {
    let select: (String) -> Void
    let toggle: (String, Bool) -> Void

    init(select: @escaping (String) -> Void, toggle: @escaping (String, Bool) -> Void = { _, _ in }) {
        self.select = select
        self.toggle = toggle
    }
}

struct WhitegramHistoryRow: ItemListNodeEntry {
    let id: String
    let index: Int
    let section: ItemListSectionId
    let title: String
    var detail: String = ""
    var additionalDetail: String?
    var value: Bool?
    var isInfo: Bool = false

    var stableId: String { return self.id }
    static func ==(lhs: Self, rhs: Self) -> Bool {
        return lhs.id == rhs.id && lhs.index == rhs.index && lhs.section == rhs.section && lhs.title == rhs.title && lhs.detail == rhs.detail && lhs.additionalDetail == rhs.additionalDetail && lhs.value == rhs.value && lhs.isInfo == rhs.isInfo
    }
    static func <(lhs: Self, rhs: Self) -> Bool { return lhs.index < rhs.index }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let actions = arguments as! WhitegramHistoryListActions
        if let value {
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: self.title, value: value, sectionId: self.section, style: .blocks, updated: { actions.toggle(self.id, $0) })
        } else if self.isInfo {
            return ItemListTextItem(presentationData: presentationData, text: .plain(self.title), sectionId: self.section, style: .blocks)
        } else {
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: self.title, label: self.detail, labelStyle: .multilineDetailText, additionalDetailLabel: self.additionalDetail, sectionId: self.section, style: .blocks, action: { actions.select(self.id) })
        }
    }
}

func whitegramHistoryEntryController(context: AccountContext, entry: WhitegramHistoryEntry) -> ViewController {
    weak var screen: ViewController?
    let actions = WhitegramHistoryListActions(select: { id in
        switch id {
        case "copy": UIPasteboard.general.string = entry.text
        case "versions": screen?.navigationController?.pushViewController(whitegramHistoryController(context: context, scope: .message(entry.messageIdentity)), animated: true)
        case "chat": screen?.navigationController?.pushViewController(whitegramHistoryController(context: context, scope: .peer(entry.peerId)), animated: true)
        default: break
        }
    })
    let signal = context.sharedContext.presentationData
    |> deliverOnMainQueue
    |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let strings = WhitegramHistoryPresentation(presentationData)
        var rows: [WhitegramHistoryRow] = []
        func info(_ id: String, _ text: String, section: ItemListSectionId = 0) {
            rows.append(WhitegramHistoryRow(id: id, index: rows.count, section: section, title: text, isInfo: true))
        }
        info("identity", "\(strings.text("Chat", "Чат")): \(entry.peerTitle ?? entry.peerId) [\(entry.peerId)]\n\(strings.text("Message", "Сообщение")): \(entry.messageId) · \(strings.text("Local revision", "Локальная ревизия")): \(entry.revision)")
        info("author", "\(strings.text("Author", "Автор")): \(entry.authorName ?? entry.authorId ?? "—")\(entry.outgoing ? strings.text(" · outgoing", " · исходящее") : "")")
        info("sent", "\(strings.text("Originally sent", "Исходное время отправки")): \(strings.date(Double(entry.messageDate)))")
        if let editedAt = entry.editedAt {
            info("edited", "\(strings.text("This version's edit time", "Время изменения этой версии")): \(strings.date(Double(editedAt)))")
        }
        info("captured", "\(strings.text("Captured locally", "Сохранено на устройстве")): \(strings.date(entry.capturedAt))\n\(strings.text("The capture time is when this device observed the event, not a server deletion timestamp.", "Время сохранения — момент получения события этим устройством, а не время удаления на сервере."))")
        info("text", entry.text.isEmpty ? strings.summary(entry) : entry.text, section: 1)
        if entry.textTruncated == true {
            info("truncated", strings.text("This archived version was truncated when captured. Its missing text cannot be reconstructed.", "Эта версия была обрезана при сохранении. Отсутствующую часть текста восстановить нельзя."), section: 1)
        }
        for (index, media) in (entry.media ?? []).enumerated() {
            info("media:\(index)", strings.metadata(media), section: 2)
        }
        if entry.mediaCount > 0 {
            let missing = entry.mediaCount - (entry.media?.count ?? 0)
            if missing > 0 {
                info("missingMedia", strings.text("\(missing) attachment(s) have no saved metadata.", "Для \(missing) вложений метаданные не сохранены."), section: 2)
            }
            info("mediaScope", strings.text("Attachment metadata only. Media bytes and thumbnails are not backed up and cannot be opened from this archive.", "Сохранены только метаданные вложений. Файлы и миниатюры не резервируются и недоступны для открытия из архива."), section: 2)
        }
        if !entry.text.isEmpty {
            rows.append(WhitegramHistoryRow(id: "copy", index: rows.count, section: 3, title: strings.text("Copy archived text", "Копировать текст из архива")))
        }
        rows.append(WhitegramHistoryRow(id: "versions", index: rows.count, section: 3, title: strings.text("All versions of this message", "Все версии этого сообщения")))
        rows.append(WhitegramHistoryRow(id: "chat", index: rows.count, section: 3, title: strings.text("This chat's archive", "Архив этого чата")))
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(strings.event(entry.event)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: rows, style: .blocks, animateChanges: false), actions))
    }
    let controller = ItemListController(context: context, state: signal)
    screen = controller
    return controller
}
