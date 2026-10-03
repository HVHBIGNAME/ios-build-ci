import Foundation
import UIKit
import AccountContext
import Display
import ItemListUI
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

private extension WhitegramGlassSettings.Toggle {
    var localizationKey: String {
        return self == .liquidGlassBubbles ? "s.liquidGlass" : "s." + self.rawValue
    }

    var isSurface: Bool {
        switch self {
        case .glassTinting, .fakeLiquidGlass, .colorInsteadOfGlass, .lightChatUI: return false
        default: return true
        }
    }
}

private struct WhitegramGlassEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case preview(PresentationData, WhitegramAppearanceSettings)
        case toggle(WhitegramGlassSettings.Toggle, Bool, Bool)
        case info(String)
        case reset(String)
    }

    let stableId: String
    let order: Int
    let section: ItemListSectionId
    let content: Content
    static func < (lhs: Self, rhs: Self) -> Bool { return lhs.order < rhs.order }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let coordinator = arguments as! WhitegramGlassCoordinator
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
                ])
        case let .toggle(toggle, value, enabled):
            let title = WhitegramLocalization.string(toggle.localizationKey, baseLanguage: presentationData.strings.baseLanguageCode)
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title,
                value: value, enabled: enabled, maximumNumberOfLines: 3, sectionId: self.section, style: .blocks,
                updated: { coordinator.save(WhitegramGlassSettings.changes(for: toggle, enabled: $0)) })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .reset(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .generic,
                alignment: .natural, sectionId: self.section, style: .blocks,
                action: { coordinator.save(WhitegramGlassSettings.resetValues) })
        }
    }
}

private final class WhitegramGlassCoordinator {
    let context: AccountContext
    let error = ValuePromise<String?>(nil, ignoreRepeated: true)

    init(context: AccountContext) { self.context = context }

    func save(_ changes: [String: Any]) {
        if WhitegramPreferences.update(changes) {
            self.error.set(nil)
        } else {
            let russian = self.context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode.lowercased().hasPrefix("ru") }
            self.error.set(russian ? "Не удалось сохранить настройки." : "Could not save settings.")
        }
    }
}

public func whitegramGlassController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramGlassCoordinator(context: context)
    let signal = combineLatest(context.sharedContext.presentationData, WhitegramAppearanceSettings.signal(), coordinator.error.get())
    |> deliverOnMainQueue
    |> map { presentationData, appearance, error -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = WhitegramGlassSettings.current
        let language = presentationData.strings.baseLanguageCode
        func text(_ key: String) -> String { return WhitegramLocalization.string(key, baseLanguage: language) }
        var entries: [WhitegramGlassEntry] = []
        func add(_ id: String, _ section: Int32, _ content: WhitegramGlassEntry.Content) {
            entries.append(WhitegramGlassEntry(stableId: id, order: entries.count, section: section, content: content))
        }
        add("preview", 0, .preview(presentationData, appearance))
        if let error { add("error", 0, .info(error)) }
        for toggle in WhitegramGlassSettings.Toggle.allCases where toggle.isSurface {
            add(toggle.rawValue, 1, .toggle(toggle, settings.isSelected(toggle), !settings.classicInterface))
        }
        add("blurInfo", 1, .info(text("wh.liquidGlass")))
        if settings.classicInterface {
            let russian = language.lowercased().hasPrefix("ru")
            add("classic", 1, .info(russian
                ? "В сохранённых настройках включён старый интерфейс. Дополнительные стеклянные поверхности отключены."
                : "The saved classic-interface preference disables the additional glass surfaces."))
        }
        for toggle in WhitegramGlassSettings.Toggle.allCases where !toggle.isSurface {
            add(toggle.rawValue, 2, .toggle(toggle, settings.isSelected(toggle), true))
        }
        add("replacementInfo", 2, .info(text("wh.fakeLiquidGlass")))
        add("reset", 3, .reset(text("common.reset")))

        let data = ItemListPresentationData(presentationData)
        let controller = ItemListControllerState(presentationData: data, title: .text(text("section.liquidGlass")),
            leftNavigationButton: nil, rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let list = ItemListNodeState(presentationData: data, entries: entries, style: .blocks, animateChanges: false)
        return (controller, (list, coordinator))
    }
    return ItemListController(context: context, state: signal)
}
