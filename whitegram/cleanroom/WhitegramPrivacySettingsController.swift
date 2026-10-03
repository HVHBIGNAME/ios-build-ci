import Foundation
import AccountContext
import Display
import ItemListUI
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

private struct WhitegramPrivacyEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case header(String)
        case toggle(String, Bool)
        case text(String)
        case retainedMedia(String)
        case location(String, String)
    }
    let stableId: String
    let order: Int
    let section: ItemListSectionId
    let content: Content

    static func < (lhs: Self, rhs: Self) -> Bool { return lhs.order < rhs.order }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let coordinator = arguments as! WhitegramPrivacyCoordinator
        switch content {
        case let .header(title):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: title, sectionId: section)
        case let .toggle(title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: section, style: .blocks, updated: { coordinator.set($0, for: self.stableId) })
        case let .text(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: section, style: .blocks)
        case let .retainedMedia(title):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: "", sectionId: section, style: .blocks, action: { coordinator.openRetainedMedia() })
        case let .location(title, detail):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: detail, sectionId: section, style: .blocks, action: { coordinator.openLocationPicker() })
        }
    }
}

private final class WhitegramPrivacyCoordinator {
    let context: AccountContext
    let updates = ValuePromise<Int>(0, ignoreRepeated: true)
    weak var controller: ItemListController?
    private var revision = 0
    private var observer: NSObjectProtocol?
    private(set) var error: String?

    init(context: AccountContext) {
        self.context = context
        observer = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func refresh() { revision += 1; updates.set(revision) }

    func set(_ value: Bool, for key: String) {
        error = WhitegramContentSettings.set(value, for: key) ? nil : "Could not save privacy settings."
        refresh()
    }

    func openRetainedMedia() {
        (controller?.navigationController as? NavigationController)?.pushViewController(whitegramContentMediaController(context: context))
    }

    func openLocationPicker() {
        let picker = whitegramContentLocationPicker(context: context) { [weak self] saved in
            guard let self else { return }
            self.error = saved ? nil : "Could not save the selected location."
            self.refresh()
        }
        (controller?.navigationController as? NavigationController)?.pushViewController(picker)
    }
}

private func whitegramPrivacyEntries(_ data: PresentationData, error: String?) -> [WhitegramPrivacyEntry] {
    let language = data.strings.baseLanguageCode
    let russian = WhitegramLocalization.selectedLanguage(baseLanguage: language) == "ru"
    func text(_ ru: String, _ en: String) -> String { return russian ? ru : en }
    func localized(_ key: String) -> String { return WhitegramLocalization.string(key, baseLanguage: language) }
    let titles = [
        "ghostModeEnabled": "h.ghost", "alwaysOnline": "s.alwaysOnline",
        "disableOnlineStatus": "s.disableOnline", "disableTypingStatus": "s.disableTyping",
        "disableRecordingStatus": "s.disableRecording", "disableUploadingStatus": "s.disableUploading",
        "disableReadReceipts": "s.disableReadReceipts", "disableStoryReadReceipts": "s.disableStoryRead",
        "readOnAction": "s.readOnAction", "disableAds": "s.disableAds",
        "saveProtectedContent": "s.protectedContent", "removeSpoilers": "s.removeSpoilers",
        "bypassContentRestrictions": "s.bypassContentRestrictions", "keepBannedChats": "s.keepBannedChats",
        "warnBeforeCall": "s.warnBeforeCall", "saveViewOnceMedia": "s.saveViewOnce",
        "ghostModeRecordOnce": "s.ghostRecordOnce", "fakeLocationEnabled": "s.fakeLocation"
    ]
    var rows: [WhitegramPrivacyEntry] = []
    func add(_ id: String, _ section: Int32, _ content: WhitegramPrivacyEntry.Content) {
        rows.append(WhitegramPrivacyEntry(stableId: id, order: rows.count, section: section, content: content))
    }
    func toggle(_ key: String, _ section: Int32, _ ru: String, _ en: String) {
        let title = WhitegramLocalization.string(titles[key] ?? "privacy." + key, baseLanguage: language, fallback: text(ru, en))
        add(key, section, .toggle(title, WhitegramContentSettings.bool(key)))
    }
    if let error { add("error", 0, .text(error)) }
    add("ghostModeHeader", 0, .header(localized("h.ghost")))
    toggle("ghostModeEnabled", 0, "Режим призрака", "Ghost Mode")
    toggle("alwaysOnline", 0, "Всегда онлайн", "Always Online")
    toggle("disableOnlineStatus", 0, "Скрыть онлайн-статус", "Hide Online Status")
    toggle("disableTypingStatus", 0, "Скрыть статус набора текста", "Hide Typing Status")
    toggle("disableRecordingStatus", 0, "Скрыть статус записи", "Hide Recording Status")
    toggle("disableUploadingStatus", 0, "Скрыть статус загрузки файлов", "Hide Uploading Status")
    toggle("disableReadReceipts", 0, "Скрыть прочтение сообщений", "Hide Read Receipts")
    toggle("disableStoryReadReceipts", 0, "Скрыть просмотр сторис", "Hide Story Views")
    toggle("suggestGhostForStories", 0, "Предлагать скрыть просмотр сторис", "Ask to Hide Story Views")
    toggle("readOnAction", 0, "Читать при действиях", "Read on Action")
    add("ghostModeInfo", 0, .text(text("Читать при действиях: отправка сообщения или реакция подтверждает прочтение до видимого сообщения. Запрет прочтения и режим призрака имеют приоритет. Всегда онлайн работает, пока клиент может выполнять запросы.", "Read on Action sends a receipt up to the visible message when you send or react. Read-receipt suppression and ghost mode take precedence. Always Online works while the client can execute requests.")))
    add("privacyHeader", 1, .header(localized("h.privacy")))
    toggle("disableAds", 1, "Отключить рекламу", "Disable Ads")
    toggle("saveProtectedContent", 1, "Сохранение защищённого контента", "Save Protected Content")
    toggle("removeSpoilers", 1, "Убрать спойлеры", "Reveal Spoilers")
    toggle("bypassContentRestrictions", 1, "Обход ограничений контента", "Bypass Content Restrictions")
    toggle("keepBannedChats", 1, "Сохранять заблокированные чаты", "Keep Banned Chats")
    add("privacyInfo", 1, .text(text("Сохранение и копирование используют доступные клиенту данные. Запрет пересылки на сервере сохраняется. Содержимое исчезающих медиа сохраняется локально перед удалением, если файл уже загружен.", "Saving and copying use data available to this client. Server forwarding restrictions still apply. Downloaded disappearing media is retained locally before expiry.")))
    add("actions", 2, .header(text("ДЕЙСТВИЯ", "ACTIONS")))
    toggle("warnBeforeCall", 2, "Предупреждать перед звонком", "Warn Before Call")
    toggle("saveViewOnceMedia", 2, "Сохранять одноразовые медиа в галерею", "Save View-once Media to Photos")
    toggle("ghostModeRecordOnce", 2, "Отправлять записи одноразово", "Send Recordings as View-once")
    add("retainedMedia", 2, .retainedMedia(text("Сохранённые исчезающие медиа", "Retained Media")))
    add("viewOnceInfo", 2, .text(text("Загруженные фото, видео и кружки сохраняются в Фото при просмотре. Голосовые доступны в локальных копиях. Ошибки доступа к Фото отображаются в разделе сохранённых медиа. Одноразовая отправка доступна в личных чатах с людьми.", "Downloaded photos, videos and video messages are saved to Photos when viewed. Voice messages remain available as local copies. Photos errors appear in Retained Media. View-once sending is available in personal chats with people.")))
    add("locationHeader", 3, .header(localized("map.fakeLocation")))
    toggle("fakeLocationEnabled", 3, "Подменять геолокацию", "Spoof Location")
    let coordinate = WhitegramContentLocation.configured.map { String(format: "%.5f, %.5f", $0.latitude, $0.longitude) } ?? localized("s.fakeLocationNotSet")
    add("fakeLocationPicker", 3, .location(localized("s.fakeLocationPicker"), coordinate))
    add("locationInfo", 3, .text(text("Выбранная точка используется как текущая геопозиция в картах Telegram. Активные трансляции геопозиции используют отдельный механизм обновлений.", "The selected point replaces the current position in Telegram maps. Active live-location broadcasts use a separate update path.")))
    return rows
}

public func whitegramPrivacySettingsController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramPrivacyCoordinator(context: context)
    let state = combineLatest(context.sharedContext.presentationData, coordinator.updates.get())
    |> deliverOnMainQueue
    |> map { data, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let presentation = ItemListPresentationData(data)
        let title = WhitegramLocalization.string("section.privacy", baseLanguage: data.strings.baseLanguageCode)
        return (ItemListControllerState(presentationData: presentation, title: .text(title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: data.strings.Common_Back), animateChanges: false), (ItemListNodeState(presentationData: presentation, entries: whitegramPrivacyEntries(data, error: coordinator.error), style: .blocks, animateChanges: false), coordinator))
    }
    let controller = ItemListController(context: context, state: state)
    coordinator.controller = controller
    return controller
}
