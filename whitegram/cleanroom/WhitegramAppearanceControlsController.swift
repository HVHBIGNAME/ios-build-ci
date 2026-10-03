import Foundation
import UIKit
import AccountContext
import Display
import ItemListUI
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

private struct WhitegramAppearanceControlEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case text(String)
        case toggle(String, String, Bool)
        case slider(String, String, Double, Double, Double, String)
        case custom(String, String)
        case reset(String)
    }
    let stableId: String
    let order: Int
    let section: ItemListSectionId
    let content: Content
    static func < (lhs: Self, rhs: Self) -> Bool { return lhs.order < rhs.order }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let coordinator = arguments as! WhitegramAppearanceControlsCoordinator
        switch self.content {
        case let .text(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .toggle(key, title, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, sectionId: self.section, style: .blocks, updated: { coordinator.save([key: $0]) })
        case let .slider(key, title, value, lower, upper, suffix):
            return WhitegramAppearanceSliderItem(presentationData: presentationData, title: title, range: lower ... upper, value: value, suffix: suffix, sectionId: self.section, updated: { value in
                if key == "stickerSizeScale" { coordinator.save([key: value / 100.0]) }
                else if key == "localStarsCount" { coordinator.save([key: Int64(value)]) }
                else { coordinator.save([key: value]) }
            })
        case let .custom(key, value):
            let title = coordinator.localized(key == "localStarsCount" ? "s.starsCustom" : (key == "tabBarScale" ? "s.tabBarScale" : "s.stickerSize"))
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: value, sectionId: self.section, style: .blocks, action: { coordinator.editValue(key) })
        case let .reset(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { coordinator.reset() })
        }
    }
}

private final class WhitegramAppearanceControlsCoordinator {
    let context: AccountContext
    let starsOnly: Bool
    let error = ValuePromise<String?>(nil, ignoreRepeated: true)
    weak var controller: ItemListController?
    private weak var alert: UIAlertController?

    init(context: AccountContext, starsOnly: Bool) { self.context = context; self.starsOnly = starsOnly }
    deinit {
        if let alert = self.alert { DispatchQueue.main.async { alert.dismiss(animated: false, completion: nil) } }
    }

    func text(_ ru: String, _ en: String) -> String {
        return self.context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode.lowercased().hasPrefix("ru") } ? ru : en
    }

    func localized(_ key: String) -> String {
        return WhitegramLocalization.string(key, baseLanguage: self.context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode })
    }

    func save(_ changes: [String: Any]) {
        self.error.set(WhitegramPreferences.update(changes) ? nil : self.text("Не удалось сохранить настройки.", "Could not save settings."))
    }

    func reset() {
        self.save(self.starsOnly ? ["localStarsEnabled": false, "localStarsCount": WhitegramLocalStars.defaultCount] : ["stickerSizeScale": 1.0, "tabBarScale": 100.0, "tabBarWidthScale": 100.0])
    }

    func editValue(_ key: String) {
        guard self.alert == nil, var presenter = self.controller?.viewIfLoaded?.window?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        let titleKey: String
        let messageKey: String
        let currentValue: String
        switch key {
        case "localStarsCount":
            titleKey = "s.starsCount"
            messageKey = "auto.WhitegramSettingsController.eb7d2a80ca"
            currentValue = String(WhitegramLocalStars.current.count)
        case "stickerSizeScale":
            titleKey = "s.stickerSize"
            messageKey = "auto.WhitegramSettingsController.9e09f2f1a2"
            currentValue = String(Int((WhitegramAppearancePolicy.current.stickerScale * 100.0).rounded()))
        case "tabBarScale":
            titleKey = "auto.WhitegramSettingsController.5c54ad3d9d"
            messageKey = "auto.WhitegramSettingsController.36fbdffcda"
            currentValue = String(WhitegramAppearancePolicy.current.tabHeightPercent)
        default:
            return
        }
        let alert = UIAlertController(title: self.localized(titleKey), message: self.localized(messageKey), preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = key == "tabBarScale" ? .decimalPad : .numberPad
            field.text = currentValue
        }
        alert.addAction(UIAlertAction(title: self.localized("common.cancel"), style: .cancel, handler: { [weak self] _ in self?.alert = nil }))
        alert.addAction(UIAlertAction(title: self.localized("common.save"), style: .default, handler: { [weak self, weak alert] _ in
            guard let self else { return }
            self.alert = nil
            let input = alert?.textFields?.first?.text ?? ""
            let value: Any?
            switch key {
            case "localStarsCount": value = WhitegramLocalStars.parseCount(input)
            case "stickerSizeScale": value = WhitegramAppearancePolicy.parseStickerPercent(input)
            case "tabBarScale": value = WhitegramAppearancePolicy.parseTabHeightPercent(input)
            default: value = nil
            }
            guard let value else {
                self.error.set(self.localized(messageKey))
                return
            }
            self.save([key: value])
        }))
        self.alert = alert
        presenter.present(alert, animated: true, completion: nil)
    }
}

private func whitegramAppearanceControls(context: AccountContext, starsOnly: Bool) -> ViewController {
    let coordinator = WhitegramAppearanceControlsCoordinator(context: context, starsOnly: starsOnly)
    let signal = combineLatest(context.sharedContext.presentationData, WhitegramAppearanceSettings.signal(), coordinator.error.get())
    |> deliverOnMainQueue
    |> map { presentationData, settings, error -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let russian = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        func text(_ ru: String, _ en: String) -> String { return russian ? ru : en }
        func localized(_ key: String) -> String { return WhitegramLocalization.string(key, baseLanguage: presentationData.strings.baseLanguageCode) }
        var entries: [WhitegramAppearanceControlEntry] = []
        func add(_ id: String, _ section: Int32, _ content: WhitegramAppearanceControlEntry.Content) {
            entries.append(WhitegramAppearanceControlEntry(stableId: id, order: entries.count, section: section, content: content))
        }
        if let error { add("error", 0, .text(error)) }
        if starsOnly {
            add("enabled", 1, .toggle("localStarsEnabled", localized("s.localStars"), settings.localStars.enabled))
            add("count", 1, .custom("localStarsCount", String(settings.localStars.count)))
            add("slider", 1, .slider("localStarsCount", localized("s.starsCount"), Double(settings.localStars.count), Double(WhitegramLocalStars.sliderRange.lowerBound), Double(WhitegramLocalStars.sliderRange.upperBound), ""))
            add("info", 1, .text(localized("wh.localStars")))
            add("reset", 2, .reset(text("Сбросить локальные звёзды", "Reset Local Stars")))
        } else {
            add("stickerValue", 1, .custom("stickerSizeScale", String(Int((settings.policy.stickerScale * 100.0).rounded())) + "%"))
            add("sticker", 1, .slider("stickerSizeScale", localized("s.stickerSize"), settings.policy.stickerScale * 100, WhitegramAppearancePolicy.stickerPercentRange.lowerBound, WhitegramAppearancePolicy.stickerPercentRange.upperBound, "%"))
            add("tabHeightValue", 1, .custom("tabBarScale", String(Int(settings.policy.tabHeightPercent)) + "%"))
            add("tabHeight", 1, .slider("tabBarScale", localized("s.tabBarScale"), settings.policy.tabHeightPercent, WhitegramAppearancePolicy.tabPercentRange.lowerBound, WhitegramAppearancePolicy.tabPercentRange.upperBound, "%"))
            add("tabs", 1, .slider("tabBarWidthScale", localized("s.tabBarWidth"), settings.policy.tabWidthPercent, WhitegramAppearancePolicy.tabPercentRange.lowerBound, WhitegramAppearancePolicy.tabPercentRange.upperBound, "%"))
            add("reset", 1, .reset(text("Восстановить размеры", "Reset Sizes")))
            for (key, titleKey) in [
                ("hideReactions", "s.hideReactions"),
                ("hideAccountRating", "s.hideAccountRating"),
                ("showPeerIDAndDC", "s.showPeerIDDC"),
                ("showChatCreationDate", "s.chatCreationDate")
            ] {
                add(key, 2, .toggle(key, localized(titleKey), settings.policy.isEnabled(key)))
            }
            add("hideAllChatsTab", 2, .toggle("hideAllChatsTab", text("Скрыть вкладку «Все чаты»", "Hide All Chats Folder"), settings.policy.isEnabled("hideAllChatsTab")))
            add("info", 2, .text(text("DC берётся из фотографии профиля, когда он доступен. Дата создания показывается у групп и каналов. «Все чаты» скрывается только при наличии другой папки.", "Photo DC is shown when available. Creation dates are shown for groups and channels. All Chats is hidden only when another folder exists.")))
        }
        let data = ItemListPresentationData(presentationData)
        return (ItemListControllerState(presentationData: data, title: .text(starsOnly ? text("Локальные звёзды", "Local Stars") : text("Интерфейс", "Interface")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false),
                (ItemListNodeState(presentationData: data, entries: entries, style: .blocks, animateChanges: false), coordinator))
    }
    let controller = ItemListController(context: context, state: signal)
    coordinator.controller = controller
    return controller
}

public func whitegramAppearanceControlsController(context: AccountContext) -> ViewController {
    return whitegramAppearanceControls(context: context, starsOnly: false)
}

public func whitegramLocalStarsController(context: AccountContext) -> ViewController {
    return whitegramAppearanceControls(context: context, starsOnly: true)
}
