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
    private var observers: [NSObjectProtocol] = []

    init(context: AccountContext) {
        self.context = context
        for name in [WhitegramPreferences.updatedNotification, WhitegramLocalizationStore.changedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.changed() })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    func changed() { self.revision += 1; self.updates.set(self.revision) }

    func update(_ id: String, value: Bool) {
        guard let key = WhitegramPortCapabilities.booleans[id] else { return }
        let changes: [String: Any]
        if let toggle = WhitegramGlassSettings.Toggle(rawValue: key) {
            changes = WhitegramGlassSettings.changes(for: toggle, enabled: value)
        } else if let toggle = WhitegramAppearanceToggle(rawValue: key) {
            changes = WhitegramAppearanceSettings.changes(for: toggle, enabled: value)
        } else {
            changes = [key: value]
        }
        if !WhitegramPreferences.update(changes) {
            self.saveFailed()
        } else if key == "whitegramNotificationsEnabled", value {
            self.context.sharedContext.applicationBindings.registerForNotifications { _ in }
        }
        self.changed()
    }

    func updateNumber(_ control: WhitegramSettingsNumber, value: Double) {
        if !control.save(value) { self.saveFailed() }
        self.changed()
    }

    private func saveFailed() {
        let alert = UIAlertController(title: "Whitegram", message: "Could not save preference.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        self.controller?.present(alert, animated: true)
    }

    func selectCamera(_ id: String) {
        guard id == "cameraFront" || id == "cameraBack" else { return }
        if !WhitegramPreferences.set(id == "cameraFront" ? 0 : 1, for: "videoMessageCamera") { self.saveFailed() }
        self.changed()
    }

    func open(_ id: String) {
        guard let screen = WhitegramPortCapabilities.screens[id] else { return }
        let target: ViewController
        switch screen {
        case "diagnostics": target = whitegramDiagnosticsController(context: self.context)
        case "localization": target = whitegramLocalizationController(context: self.context)
        case "keychainAccounts": target = whitegramKeychainAccountsController(context: self.context)
        case "accountTransfer": target = whitegramAccountTransferController(context: self.context)
        case "botAccounts": target = whitegramBotAccountsController(context: self.context)
        case "player": target = whitegramPlayerSettingsController(context: self.context)
        case "equalizer": target = whitegramPlayerEqualizerController(context: self.context)
        case "radio": target = whitegramRadioController(context: self.context)
        case "traffic": target = whitegramTrafficController(context: self.context)
        case "profile": target = whitegramProfileController(context: self.context)
        case "profilePhotos": target = whitegramProfilePhotosController(context: self.context, userId: self.context.account.peerId.id._internalGetInt64Value())
        case "profileWall": target = whitegramProfileWallController(context: self.context, userId: self.context.account.peerId.id._internalGetInt64Value())
        case "streaks": target = whitegramProfileStreakController(context: self.context)
        case "appearanceControls": target = whitegramAppearanceControlsController(context: self.context)
        case "localStars": target = whitegramLocalStarsController(context: self.context)
        case "glass": target = whitegramGlassController(context: self.context)
        case "iconPacks": target = whitegramIconPacksController(context: self.context)
        case "media": target = whitegramMediaSettingsController(context: self.context)
        case "location": target = whitegramContentLocationPicker(context: self.context) { [weak self] saved in
            if !saved { self?.saveFailed() }
            self?.changed()
        }
        case "translation": target = whitegramTranslationSettingsController(context: self.context)
        case "settingsTransfer": target = whitegramSettingsTransferController(context: self.context, action: WhitegramSettingsTransferAction(rawValue: id))
        case "appearanceExtensions": target = whitegramAppearanceController(context: self.context)
        case "history":
            guard let action = WhitegramHistoryAction(rawValue: id) else { return }
            target = whitegramHistoryActionController(context: self.context, action: action)
        case "chats": target = whiteGramChatSettingsController(context: self.context)
        case "tabs": target = whiteGramTabsSettingsController(context: self.context)
        case "fonts": target = whitegramFontsController(context: self.context)
        case "plugins": target = whitegramPluginManagerController(context: self.context)
        case "voice": target = whitegramVoiceSettingsController(context: self.context)
        case "voiceRemote": target = whitegramVoiceRemoteSettingsController(context: self.context)
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
    let number: Double?
    let camera: Int?
    let revision: Int
    let russian: Bool

    var section: ItemListSectionId { return Int32(self.descriptor.section) }
    var stableId: String { return self.descriptor.id }
    static func ==(lhs: Self, rhs: Self) -> Bool { return lhs.stableId == rhs.stableId && lhs.title == rhs.title && lhs.value == rhs.value && lhs.number == rhs.number && lhs.camera == rhs.camera && lhs.revision == rhs.revision && lhs.russian == rhs.russian }
    static func <(lhs: Self, rhs: Self) -> Bool { return lhs.descriptor.order < rhs.descriptor.order }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! WhitegramSettingsCoordinator
        if self.descriptor.kind == .headerRow {
            return ItemListSectionHeaderItem(presentationData: presentationData, text: self.title, sectionId: self.section)
        }
        if WhitegramPortCapabilities.informationKeys[self.descriptor.id] != nil {
            return ItemListTextItem(presentationData: presentationData, text: .plain(self.title), sectionId: self.section, style: .blocks)
        }
        if self.descriptor.id == "messagePreview" {
            let data = arguments.context.sharedContext.currentPresentationData.with { $0 }
            return ThemeSettingsChatPreviewItem(context: arguments.context, systemStyle: .glass, theme: data.theme, componentTheme: data.theme,
                strings: data.strings, sectionId: self.section, fontSize: data.chatFontSize, chatBubbleCorners: data.chatBubbleCorners,
                wallpaper: data.chatWallpaper, dateTimeFormat: data.dateTimeFormat, nameDisplayOrder: data.nameDisplayOrder,
                messageItems: [
                    ChatPreviewMessageItem(outgoing: false, reply: nil, text: data.strings.Appearance_PreviewIncomingText, nameColor: .preset(.blue), backgroundEmojiId: nil),
                    ChatPreviewMessageItem(outgoing: true, reply: nil, text: data.strings.Appearance_PreviewOutgoingText, nameColor: .preset(.blue), backgroundEmojiId: nil)
                ])
        }
        if let control = WhitegramSettingsNumber(rawValue: self.descriptor.id), let number = self.number {
            return WhitegramAppearanceSliderItem(presentationData: presentationData, title: self.title, range: control.range, value: number,
                suffix: control.suffix, step: control.step, fractionDigits: control.fractionDigits, sectionId: self.section,
                updated: { arguments.updateNumber(control, value: $0) })
        }
        if self.descriptor.id == "cameraFront" || self.descriptor.id == "cameraBack" {
            let selected = self.camera == (self.descriptor.id == "cameraFront" ? 0 : 1)
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: self.title,
                style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section,
                action: { arguments.selectCamera(self.descriptor.id) })
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
    |> map { presentationData, revision -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let russian = WhitegramLocalization.selectedLanguage(baseLanguage: presentationData.strings.baseLanguageCode) == "ru"
        let hideDescriptions = WhitegramPreferences.bool("hideSettingsDescriptions", default: UserDefaults.standard.bool(forKey: "wg_hideSettingsDescriptions"))
        let descriptors = WhitegramSettingsList.filtered(WhitegramSettingsCatalog.rows, sections: sections, query: coordinator.query,
            availableOnly: availableOnly, hideDescriptions: hideDescriptions, informationIds: Set(WhitegramPortCapabilities.informationKeys.keys),
            supported: { WhitegramPortCapabilities.supports($0) || WhitegramSettingsNumber(rawValue: $0) != nil || $0 == "messagePreview" },
            title: { WhitegramPortCapabilities.title($0, baseLanguage: presentationData.strings.baseLanguageCode) })
        let rows = descriptors.map { descriptor -> WhitegramSettingsRow in
            let rowTitle = WhitegramPortCapabilities.title(descriptor, baseLanguage: presentationData.strings.baseLanguageCode)
            let value = WhitegramPortCapabilities.booleanValue(descriptor.id)
            let number = WhitegramSettingsNumber(rawValue: descriptor.id)?.value
            return WhitegramSettingsRow(descriptor: descriptor, title: rowTitle, value: value, number: number,
                camera: WhitegramMediaSettings.current.videoMessageCamera ?? 0, revision: revision, russian: russian)
        }
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: ItemListNavigationButton(content: .icon(.search), style: .regular, enabled: true, action: { coordinator.search() }), backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: rows, style: .blocks, animateChanges: false)
        return (state, (list, coordinator))
    }
    let controller = ItemListController(context: context, state: signal)
    coordinator.controller = controller
    return controller
}
