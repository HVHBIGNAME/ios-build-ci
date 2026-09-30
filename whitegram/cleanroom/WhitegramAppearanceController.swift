import Foundation
import UIKit
import AccountContext
import Display
import ItemListUI
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

private extension WhitegramAppearanceToggle {
    func title(russian: Bool) -> String {
        switch self {
        case .messageBorderEnabled: return russian ? "Обводка сообщений" : "Message Borders"
        case .transparentMessages: return russian ? "Прозрачные сообщения" : "Transparent Messages"
        case .semiTransparentBubbles: return russian ? "Полупрозрачные пузыри" : "Semi-transparent Bubbles"
        case .showCharCountTyping: return russian ? "Счётчик при наборе" : "Character Count While Typing"
        case .showCharCountMessages: return russian ? "Счётчик в сообщениях" : "Character Count in Messages"
        case .showActionTime: return russian ? "Время служебных сообщений" : "Service Message Timestamps"
        case .hideBusinessBotPanel: return russian ? "Скрыть панель бизнес-бота" : "Hide Business Bot Panel"
        }
    }
}

private struct WhitegramAppearanceEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case preview(PresentationData, WhitegramAppearanceSettings)
        case header(String)
        case info(String)
        case toggle(WhitegramAppearanceToggle, Bool)
        case color(String, Bool)
        case reset
    }

    let stableId: String
    let order: Int
    let section: ItemListSectionId
    let content: Content

    static func < (lhs: WhitegramAppearanceEntry, rhs: WhitegramAppearanceEntry) -> Bool {
        return lhs.order < rhs.order
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let coordinator = arguments as! WhitegramAppearanceCoordinator
        let russian = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        switch self.content {
        case let .preview(data, _):
            return ThemeSettingsChatPreviewItem(
                context: coordinator.context, systemStyle: .glass, theme: data.theme, componentTheme: data.theme,
                strings: data.strings, sectionId: self.section, fontSize: data.chatFontSize,
                chatBubbleCorners: data.chatBubbleCorners, wallpaper: data.chatWallpaper,
                dateTimeFormat: data.dateTimeFormat, nameDisplayOrder: data.nameDisplayOrder,
                messageItems: [
                    ChatPreviewMessageItem(outgoing: false, reply: nil, text: data.strings.Appearance_PreviewIncomingText, nameColor: .preset(.blue), backgroundEmojiId: nil),
                    ChatPreviewMessageItem(outgoing: true, reply: nil, text: data.strings.Appearance_PreviewOutgoingText, nameColor: .preset(.blue), backgroundEmojiId: nil)
                ]
            )
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .toggle(toggle, value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: toggle.title(russian: russian),
                value: value, sectionId: self.section, style: .blocks,
                updated: { coordinator.set(toggle, enabled: $0, russian: russian) })
        case let .color(hex, enabled):
            let label = hex.isEmpty ? (russian ? "По теме" : "Theme Accent") : hex
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass,
                title: russian ? "Цвет обводки" : "Border Color", enabled: enabled, label: label,
                sectionId: self.section, style: .blocks, action: { coordinator.editBorderColor(russian: russian) })
        case .reset:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass,
                title: russian ? "Сбросить эти настройки" : "Reset These Settings", kind: .generic,
                alignment: .natural, sectionId: self.section, style: .blocks,
                action: { coordinator.save(WhitegramAppearanceSettings.resetValues, russian: russian) })
        }
    }
}

private func whitegramAppearanceEntries(presentationData: PresentationData, settings: WhitegramAppearanceSettings, error: String?) -> [WhitegramAppearanceEntry] {
    let russian = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
    var entries: [WhitegramAppearanceEntry] = []
    func add(_ id: String, _ section: Int32, _ content: WhitegramAppearanceEntry.Content) {
        entries.append(WhitegramAppearanceEntry(stableId: id, order: entries.count, section: section, content: content))
    }
    func toggle(_ value: WhitegramAppearanceToggle, _ section: Int32) {
        add(value.rawValue, section, .toggle(value, settings.isEnabled(value)))
    }

    add("preview", 0, .preview(presentationData, settings))
    if let error { add("error", 0, .info(error)) }

    add("bubbles", 1, .header(russian ? "ПУЗЫРИ СООБЩЕНИЙ" : "MESSAGE BUBBLES"))
    toggle(.messageBorderEnabled, 1)
    add("borderColor", 1, .color(settings.messageBorderColorHex, settings.isEnabled(.messageBorderEnabled)))
    toggle(.transparentMessages, 1)
    toggle(.semiTransparentBubbles, 1)
    add("bubbleInfo", 1, .info(russian
        ? "Прозрачный режим убирает заливку и тень. Полупрозрачный оставляет заливку с непрозрачностью 65%. Текст, медиа и обводка сохраняют свою непрозрачность. Включение одного режима отключает другой."
        : "Transparent mode removes the fill and shadow. Semi-transparent mode uses 65% fill opacity. Text, media and borders retain their opacity. Enabling either mode turns the other off."))
    if settings.isEnabled(.transparentMessages) && settings.isEnabled(.semiTransparentBubbles) {
        add("bothModes", 1, .info(russian
            ? "В сохранённых данных включены оба режима. Применяется прозрачный; выберите один из режимов выше."
            : "Both modes are enabled in saved data. Transparent mode takes priority; choose a mode above to resolve this."))
    }
    if WhitegramAppearanceSettings.normalizedBorderColor(settings.messageBorderColorHex) == nil {
        add("invalidColor", 1, .info(russian
            ? "Сохранённый цвет не является шестизначным RGB. Пока используется цвет темы. Введите #RRGGBB или очистите поле."
            : "The saved border color is not six-digit RGB. The theme accent is used until you enter #RRGGBB or clear the field."))
    }

    add("metadata", 2, .header(russian ? "ТЕКСТ И ВРЕМЯ" : "TEXT AND TIME"))
    toggle(.showCharCountMessages, 2)
    toggle(.showActionTime, 2)
    add("metadataInfo", 2, .info(russian
        ? "Число символов показывается рядом со временем текстовых сообщений и подписей с обычной строкой статуса. Эмодзи и составные символы считаются как один видимый символ. Время служебных сообщений — время самого события."
        : "Character counts appear beside the time on text messages and captions with a normal status line. Emoji and combined characters count as one visible character. Service timestamps show the event message's time."))

    add("composer", 3, .header(russian ? "ПОЛЕ ВВОДА И ПАНЕЛИ" : "COMPOSER AND PANELS"))
    toggle(.showCharCountTyping, 3)
    toggle(.hideBusinessBotPanel, 3)
    add("composerInfo", 3, .info(russian
        ? "Счётчик занимает отдельную строку над вводимым текстом. При приближении к лимиту остаётся штатный счётчик оставшихся символов. Скрытие панели бизнес-бота не меняет его доступ к чату."
        : "The counter has its own row above your draft. Near a text limit, Telegram's remaining-character warning takes priority. Hiding the business bot panel does not change the bot's access to the chat."))

    add("reset", 4, .reset)
    add("portInfo", 4, .info(russian
        ? "Открытые чаты обновляются при изменении этих настроек. Визуальные детали восстановлены для Telegram 12.9.2; точное совпадение с оригинальным Whitegram не подтверждено."
        : "Open chats refresh when these settings change. Visual details are reconstructed for Telegram 12.9.2; exact visual parity with the original Whitegram is unverified."))
    return entries
}

private final class WhitegramAppearanceCoordinator {
    let context: AccountContext
    let error = ValuePromise<String?>(nil, ignoreRepeated: true)
    weak var controller: ItemListController?
    private weak var colorAlert: UIAlertController?

    init(context: AccountContext) {
        self.context = context
    }

    deinit {
        if let alert = self.colorAlert {
            DispatchQueue.main.async { alert.dismiss(animated: false, completion: nil) }
        }
    }

    func save(_ changes: [String: Any], russian: Bool) {
        if WhitegramPreferences.update(changes) {
            self.error.set(nil)
        } else {
            self.error.set(russian ? "Не удалось сохранить настройки." : "Could not save appearance settings.")
        }
    }

    func set(_ toggle: WhitegramAppearanceToggle, enabled: Bool, russian: Bool) {
        self.save(WhitegramAppearanceSettings.changes(for: toggle, enabled: enabled), russian: russian)
    }

    func editBorderColor(russian: Bool) {
        guard WhitegramAppearanceSettings.current.isEnabled(.messageBorderEnabled), self.colorAlert == nil else { return }
        guard var presenter = self.controller?.viewIfLoaded?.window?.rootViewController else {
            self.error.set(russian ? "Откройте настройки заново, чтобы выбрать цвет." : "Reopen the settings screen to choose a color.")
            return
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !presenter.isBeingDismissed && !presenter.isBeingPresented else { return }

        let alert = UIAlertController(title: russian ? "Цвет обводки" : "Border Color",
            message: russian ? "Шесть цифр RGB (#RRGGBB). Пустое поле — цвет темы." : "Six RGB digits (#RRGGBB). Leave empty to use the theme accent.", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = WhitegramAppearanceSettings.current.messageBorderColorHex
            field.placeholder = "#RRGGBB"
            field.keyboardType = .asciiCapable
            field.autocorrectionType = .no
            field.autocapitalizationType = .allCharacters
            field.spellCheckingType = .no
        }
        alert.addAction(UIAlertAction(title: russian ? "Отмена" : "Cancel", style: .cancel, handler: { [weak self] _ in
            self?.colorAlert = nil
        }))
        alert.addAction(UIAlertAction(title: russian ? "Сохранить" : "Save", style: .default, handler: { [weak self, weak alert] _ in
            guard let self, let value = alert?.textFields?.first?.text else { return }
            self.colorAlert = nil
            guard let normalized = WhitegramAppearanceSettings.normalizedBorderColor(value) else {
                self.error.set(russian ? "Цвет не сохранён. Введите шесть цифр RGB или очистите поле." : "Color was not saved. Enter six RGB digits or clear the field.")
                return
            }
            self.save([WhitegramAppearanceSettings.borderColorKey: normalized], russian: russian)
        }))
        self.colorAlert = alert
        presenter.present(alert, animated: true, completion: nil)
    }
}

public func whitegramAppearanceController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramAppearanceCoordinator(context: context)
    let signal = combineLatest(context.sharedContext.presentationData, WhitegramAppearanceSettings.signal(), coordinator.error.get())
    |> deliverOnMainQueue
    |> map { presentationData, settings, error -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let data = ItemListPresentationData(presentationData)
        let russian = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        let controllerState = ItemListControllerState(presentationData: data, title: .text(russian ? "Оформление чата" : "Chat Appearance"),
            leftNavigationButton: nil, rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: data,
            entries: whitegramAppearanceEntries(presentationData: presentationData, settings: settings, error: error), style: .blocks, animateChanges: false)
        return (controllerState, (listState, coordinator))
    }
    let controller = ItemListController(context: context, state: signal)
    coordinator.controller = controller
    return controller
}
