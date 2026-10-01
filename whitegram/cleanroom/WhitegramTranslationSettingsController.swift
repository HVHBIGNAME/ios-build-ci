import Foundation
import AccountContext
import Display
import ItemListUI
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import TelegramPresentationData
import TranslateUI

private struct WhitegramTranslationScreenState: Equatable {
    let settings: WhitegramTranslationSettings
    let native: WhiteGramOtherSettings
    let error: String?
}

private final class WhitegramTranslationSettingsCoordinator {
    let state: ValuePromise<WhitegramTranslationScreenState>
    var openLanguages: (() -> Void)?
    var openNativeSettings: (() -> Void)?
    private var error: String?
    private var observers: [NSObjectProtocol] = []

    init() {
        self.state = ValuePromise(WhitegramTranslationScreenState(settings: .current, native: .current, error: nil), ignoreRepeated: true)
        for name in [WhitegramPreferences.updatedNotification, UserDefaults.didChangeNotification] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
    }

    deinit {
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        self.state.set(WhitegramTranslationScreenState(settings: .current, native: .current, error: self.error))
    }

    func save(_ value: Any, key: String) {
        self.error = WhitegramPreferences.set(value, for: key) ? nil : "Could not save translation settings. Please try again."
        self.refresh()
    }

    func selectProvider(_ provider: WhiteGramOtherTranslationService) {
        guard WhitegramPreferences.set(false, for: WhitegramTranslationSettings.localKey) else {
            self.error = "Could not save the provider choice. Please try again."
            self.refresh()
            return
        }
        var native = WhiteGramOtherSettings.current
        native.setTranslationService(provider)
        self.error = nil
        NotificationCenter.default.post(name: WhitegramPreferences.updatedNotification, object: nil)
        self.refresh()
    }

    func showTranslationButton(_ value: Bool) {
        var native = WhiteGramOtherSettings.current
        native.setTranslationButton(value)
        NotificationCenter.default.post(name: WhitegramPreferences.updatedNotification, object: nil)
        self.refresh()
    }
}

private struct WhitegramTranslationEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case header(String)
        case info(String)
        case beforeSend(Bool)
        case automatic(Bool)
        case button(Bool)
        case target(String)
        case language(code: String, title: String, selected: Bool)
        case provider(WhiteGramOtherTranslationService, Bool)
        case nativeSettings
    }

    let stableId: String
    let order: Int
    let section: ItemListSectionId
    let content: Content

    static func < (lhs: WhitegramTranslationEntry, rhs: WhitegramTranslationEntry) -> Bool { return lhs.order < rhs.order }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! WhitegramTranslationSettingsCoordinator
        switch self.content {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .beforeSend(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Translate Before Sending", value: value, sectionId: self.section, style: .blocks, updated: { arguments.save($0, key: WhitegramTranslationSettings.beforeSendingKey) })
        case let .automatic(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Automatically Translate Chats", value: value, sectionId: self.section, style: .blocks, updated: { arguments.save($0, key: "translateMessagesEnabled") })
        case let .button(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Show Translate Button", value: value, sectionId: self.section, style: .blocks, updated: { arguments.showTranslationButton($0) })
        case let .target(label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: "Target Language", label: label, sectionId: self.section, style: .blocks, action: { arguments.openLanguages?() })
        case let .language(code, title, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, subtitle: code.isEmpty ? nil : code, style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: { arguments.save(code, key: WhitegramTranslationSettings.targetKey) })
        case let .provider(provider, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: provider.title + " · Network", subtitle: provider == .telegram ? "Supports text entities; before-send failures are shown" : "Before-send translation supports plain text only", style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: { arguments.selectProvider(provider) })
        case .nativeSettings:
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: "Do Not Translate Languages", label: "", sectionId: self.section, style: .blocks, action: { arguments.openNativeSettings?() })
        }
    }
}

private func whitegramTranslationEntries(_ state: WhitegramTranslationScreenState, locale: Locale, languagesOnly: Bool) -> [WhitegramTranslationEntry] {
    var entries: [WhitegramTranslationEntry] = []
    func add(_ id: String, _ section: Int32, _ content: WhitegramTranslationEntry.Content) {
        entries.append(WhitegramTranslationEntry(stableId: id, order: entries.count, section: section, content: content))
    }
    func title(_ code: String) -> String { return locale.localizedString(forIdentifier: code) ?? code }
    let settings = state.settings
    if let error = state.error { add("error", 0, .info(error)) }

    if languagesOnly {
        add("default", 0, .language(code: "", title: "Telegram Default", selected: !settings.hasGlobalTarget))
        add("defaultInfo", 0, .info("Default uses the app language before sending and Telegram's per-chat language for received messages. A chosen global language is used for automatic chat translation and new translation sheets; a manually selected per-chat language still takes precedence when automatic translation is off."))
        for code in supportedTranslationLanguages.sorted(by: { title($0).localizedStandardCompare(title($1)) == .orderedAscending }) {
            add("language:\(code)", 1, .language(code: code, title: title(code), selected: WhitegramTranslationSettings.supportedCode(settings.targetLanguage, in: supportedTranslationLanguages) == code))
        }
        return entries
    }

    add("target", 0, .target(settings.hasGlobalTarget ? title(settings.targetLanguage) : "Telegram Default"))
    if settings.hasGlobalTarget && settings.resolvedTarget(baseLanguage: "", supportedLanguages: supportedTranslationLanguages) == nil {
        add("invalidTarget", 0, .info("The saved language is unsupported. Before-send translation is paused until a supported language or Telegram Default is chosen."))
    }
    add("beforeSend", 0, .beforeSend(settings.beforeSending))
    add("beforeSendInfo", 0, .info("The first Send tap translates a text draft. Review the result and tap Send again to send it. Cancel or failure keeps the original. Editing text, replies or the send context invalidates pending translation. Scheduling and send options are chosen on the final send action."))

    add("providerHeader", 1, .header("TRANSLATION PROVIDER"))
    for provider in WhiteGramOtherTranslationService.allCases {
        add("provider:\(provider.rawValue)", 1, .provider(provider, state.native.translationService == provider && !settings.localTranslationRequested))
    }
    add("networkInfo", 1, .info("Both providers send text over the network. Received-message translation retains the native Telegram-to-Google fallback. Before-send translation never switches providers silently. Selecting a provider clears a saved on-device request."))

    add("receivedHeader", 2, .header("RECEIVED MESSAGES"))
    add("automatic", 2, .automatic(state.native.autoTranslate))
    add("button", 2, .button(state.native.translationButton))
    add("nativeSettings", 2, .nativeSettings)
    add("ignoredInfo", 2, .info("Do Not Translate Languages uses Telegram's native settings. Automatic translation skips the chosen target language; the native ignored-language list applies when automatic translation is off."))

    add("availabilityHeader", 3, .header("AVAILABILITY"))
    add("localInfo", 3, .info("Apple on-device translation is not enabled by this port. The native source contains an iOS 18 TranslationSession implementation, but language availability, model downloads and entity-safe draft conversion have not been integrated."))
    if settings.localTranslationRequested { add("localRequested", 3, .info("An original on-device preference is saved. Before-send network translation is blocked until you explicitly select a network provider above.")) }
    add("voiceInfo", 3, .info("Voice translation and the original Siri warning/dismissal workflow are not connected. Native voice transcription remains separate from before-send text translation."))
    if settings.voiceTranslationRequested || settings.siriWarningRequested {
        add("voiceRequested", 3, .info("Recovered voice translation/Siri preferences are retained, but do not enable that workflow."))
    }
    return entries
}

private func whitegramTranslationListController(context: AccountContext, coordinator: WhitegramTranslationSettingsCoordinator, languagesOnly: Bool) -> ViewController {
    let signal = combineLatest(context.sharedContext.presentationData, coordinator.state.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let data = ItemListPresentationData(presentationData)
        let controllerState = ItemListControllerState(presentationData: data, title: .text(languagesOnly ? "Target Language" : "Translation"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let listState = ItemListNodeState(presentationData: data, entries: whitegramTranslationEntries(state, locale: Locale(identifier: presentationData.strings.baseLanguageCode), languagesOnly: languagesOnly), style: .blocks, animateChanges: false)
        return (controllerState, (listState, coordinator))
    }
    let controller = ItemListController(context: context, state: signal)
    controller.didAppear = { [coordinator] _ in coordinator.refresh() }
    return controller
}

public func whitegramTranslationSettingsController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramTranslationSettingsCoordinator()
    let controller = whitegramTranslationListController(context: context, coordinator: coordinator, languagesOnly: false)
    coordinator.openLanguages = { [weak controller, weak coordinator] in
        guard let coordinator else { return }
        controller?.navigationController?.pushViewController(whitegramTranslationListController(context: context, coordinator: coordinator, languagesOnly: true), animated: true)
    }
    coordinator.openNativeSettings = { [weak controller] in
        controller?.navigationController?.pushViewController(translationSettingsController(context: context), animated: true)
    }
    return controller
}
