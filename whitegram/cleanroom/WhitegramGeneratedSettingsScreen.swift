import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext

private final class WhitegramSettingsCoordinator {
    let context: AccountContext
    let updates = ValuePromise<Int>(0, ignoreRepeated: true)
    var query = ""
    weak var controller: ViewController?
    private var revision = 0
    private var observer: NSObjectProtocol?

    init(context: AccountContext) {
        self.context = context
        self.observer = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: nil) { [weak self] _ in
            DispatchQueue.main.async { self?.changed() }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func changed() { self.revision += 1; self.updates.set(self.revision) }

    func update(_ id: String, value: Bool) {
        guard let key = WhitegramPortCapabilities.booleans[id] else { return }
        if !WhitegramPreferences.set(value, for: key) {
            let alert = UIAlertController(title: "Whitegram", message: "Could not save preference.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self.controller?.present(alert, animated: true)
        }
    }

    func open(_ id: String) {
        guard let screen = WhitegramPortCapabilities.screens[id] else { return }
        let target: ViewController
        switch screen {
        case "media": target = whitegramMediaSettingsController(context: self.context)
        case "translation": target = whitegramTranslationSettingsController(context: self.context)
        case "settingsTransfer": target = whitegramSettingsTransferController(context: self.context, action: WhitegramSettingsTransferAction(rawValue: id))
        case "appearanceExtensions": target = whitegramAppearanceController(context: self.context)
        case "history": target = whitegramHistoryController(context: self.context)
        case "chats": target = whiteGramChatSettingsController(context: self.context)
        case "tabs": target = whiteGramTabsSettingsController(context: self.context)
        case "fonts": target = whitegramFontsController(context: self.context)
        case "plugins": target = whitegramPluginManagerController(context: self.context)
        case "voice": target = whitegramVoiceSettingsController(context: self.context)
        case "virusTotal": target = whitegramVirusTotalController(context: self.context)
        case "ai": target = whitegramAISettingsController(context: self.context)
        default: return
        }
        self.controller?.navigationController?.pushViewController(target, animated: true)
    }

    func search() {
        let alert = UIAlertController(title: "Поиск / Search", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = self.query }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Search", style: .default, handler: { [weak self, weak alert] _ in
            self?.query = alert?.textFields?.first?.text ?? ""
            self?.changed()
        }))
        self.controller?.present(alert, animated: true)
    }
}

private struct WhitegramSettingsRow: ItemListNodeEntry {
    let descriptor: WhitegramSettingsRowDescriptor
    let title: String
    let value: Bool?
    let russian: Bool

    var section: ItemListSectionId { return Int32(self.descriptor.section) }
    var stableId: String { return self.descriptor.id }
    static func ==(lhs: Self, rhs: Self) -> Bool { return lhs.stableId == rhs.stableId && lhs.title == rhs.title && lhs.value == rhs.value && lhs.russian == rhs.russian }
    static func <(lhs: Self, rhs: Self) -> Bool { return lhs.descriptor.order < rhs.descriptor.order }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! WhitegramSettingsCoordinator
        if self.descriptor.kind == .headerRow {
            return ItemListSectionHeaderItem(presentationData: presentationData, text: self.title, sectionId: self.section)
        }
        if let value {
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: self.title, value: value, sectionId: self.section, style: .blocks, updated: { arguments.update(self.descriptor.id, value: $0) })
        }
        if WhitegramPortCapabilities.screens[self.descriptor.id] != nil {
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: self.title, label: self.russian ? "Настроить" : "Configure", sectionId: self.section, style: .blocks, action: { arguments.open(self.descriptor.id) })
        }
        let text = self.title + (self.russian ? " — реализация ещё не подключена" : " — implementation not connected")
        return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section, style: .blocks)
    }
}

public func whitegramGeneratedSettingsController(context: AccountContext, sections: Set<Int>? = nil, title: String = "Whitegram", availableOnly: Bool = false) -> ViewController {
    let coordinator = WhitegramSettingsCoordinator(context: context)
    let signal = combineLatest(context.sharedContext.presentationData, coordinator.updates.get())
    |> deliverOnMainQueue
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let russian = presentationData.strings.baseLanguageCode.hasPrefix("ru")
        let rows = WhitegramSettingsCatalog.rows.compactMap { descriptor -> WhitegramSettingsRow? in
            if let sections, !sections.contains(descriptor.section) { return nil }
            let supported = WhitegramPortCapabilities.booleans[descriptor.id] != nil || WhitegramPortCapabilities.screens[descriptor.id] != nil
            if availableOnly && !supported { return nil }
            let rowTitle = WhitegramPortCapabilities.title(descriptor, russian: russian)
            if !coordinator.query.isEmpty && !rowTitle.localizedCaseInsensitiveContains(coordinator.query) && !descriptor.id.localizedCaseInsensitiveContains(coordinator.query) { return nil }
            let value = WhitegramPortCapabilities.booleans[descriptor.id].map { WhitegramPreferences.bool($0) }
            return WhitegramSettingsRow(descriptor: descriptor, title: rowTitle, value: value, russian: russian)
        }
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: ItemListNavigationButton(content: .icon(.search), style: .regular, enabled: true, action: { coordinator.search() }), backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: rows, style: .blocks, animateChanges: false)
        return (state, (list, coordinator))
    }
    let controller = ItemListController(context: context, state: signal)
    coordinator.controller = controller
    return controller
}
