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
    let presentationRevision: UInt
}

private final class WhitegramTranslationSettingsCoordinator {
    let state: ValuePromise<WhitegramTranslationScreenState>
    var openLanguages: (() -> Void)?
    var openNativeSettings: (() -> Void)?
    private var error: String?
    private var presentationRevision: UInt = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        self.state = ValuePromise(WhitegramTranslationScreenState(settings: .current, native: .current, error: nil, presentationRevision: 0), ignoreRepeated: true)
        for name in [WhitegramPreferences.updatedNotification, UserDefaults.didChangeNotification, WhitegramLocalizationStore.changedNotification] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
    }

    deinit {
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        self.presentationRevision &+= 1
        self.state.set(WhitegramTranslationScreenState(settings: .current, native: .current, error: self.error, presentationRevision: self.presentationRevision))
    }

    func save(_ value: Any, key: String) {
        self.error = WhitegramPreferences.set(value, for: key) ? nil : "Could not save translation settings. Please try again."
        self.refresh()
    }

    func selectProvider(_ provider: WhiteGramOtherTranslationService) {
        guard WhitegramPreferences.update([WhitegramTranslationSettings.localKey: provider == .gTranslate, WhitegramTranslationSettings.appleKey: false]) else {
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

    func selectApple() {
        guard #available(iOS 18.0, *) else { return }
        self.error = WhitegramPreferences.update([WhitegramTranslationSettings.appleKey: true, WhitegramTranslationSettings.localKey: false]) ? nil : "Could not save the provider choice."
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
        case reviewBeforeSend(Bool)
        case automatic(Bool)
        case button(Bool)
        case target(String)
        case language(code: String, title: String, selected: Bool)
        case provider(WhiteGramOtherTranslationService, Bool)
        case apple(Bool)
        case voice(Bool)
        case transcripts(Bool)
        case resetSiri
        case nativeSettings
    }

    let stableId: String
    let order: Int
    let section: ItemListSectionId
    let content: Content
    let presentationRevision: UInt

    static func < (lhs: WhitegramTranslationEntry, rhs: WhitegramTranslationEntry) -> Bool { return lhs.order < rhs.order }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! WhitegramTranslationSettingsCoordinator
        switch self.content {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .beforeSend(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: WhitegramLocalization.string("s.translateBeforeSending", baseLanguage: presentationData.strings.baseLanguageCode), value: value, sectionId: self.section, style: .blocks, updated: { arguments.save($0, key: WhitegramTranslationSettings.beforeSendingKey) })
        case let .reviewBeforeSend(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Review Every Draft Before Sending", value: value, sectionId: self.section, style: .blocks, updated: { arguments.save($0, key: WhitegramTranslationSettings.reviewBeforeSendingKey) })
        case let .automatic(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Automatically Translate Chats", value: value, sectionId: self.section, style: .blocks, updated: { arguments.save($0, key: "translateMessagesEnabled") })
        case let .button(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Show Translate Button", value: value, sectionId: self.section, style: .blocks, updated: { arguments.showTranslationButton($0) })
        case let .target(label):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: WhitegramLocalization.string("s.translationTargetLang", baseLanguage: presentationData.strings.baseLanguageCode), label: label, sectionId: self.section, style: .blocks, action: { arguments.openLanguages?() })
        case let .language(code, title, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title, subtitle: code.isEmpty ? nil : code, style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: { arguments.save(code, key: WhitegramTranslationSettings.targetKey) })
        case let .provider(provider, selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: provider.title + " · Network", subtitle: provider == .telegram ? "Telegram translation API" : "Original Local Translation option: direct Google HTTP API", style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: { arguments.selectProvider(provider) })
        case let .apple(selected):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: "Apple · On Device (iOS 18+)", subtitle: "Supported language pairs; system permission for language downloads", style: .right, checked: selected, zeroSeparatorInsets: false, sectionId: self.section, action: { arguments.selectApple() })
        case let .voice(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: WhitegramLocalization.string("s.voiceTranslation", baseLanguage: presentationData.strings.baseLanguageCode), value: value, sectionId: self.section, style: .blocks, updated: { arguments.save($0, key: WhitegramTranslationSettings.voiceKey) })
        case let .transcripts(value):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Translate Completed Transcripts", value: value, sectionId: self.section, style: .blocks, updated: { arguments.save($0, key: WhitegramTranslationSettings.transcriptsKey) })
        case .resetSiri:
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: "Show Siri Warning Again", kind: .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { arguments.save(false, key: WhitegramTranslationSettings.siriDismissedKey) })
        case .nativeSettings:
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: "Do Not Translate Languages", label: "", sectionId: self.section, style: .blocks, action: { arguments.openNativeSettings?() })
        }
    }
}

private func whitegramTranslationEntries(_ state: WhitegramTranslationScreenState, locale: Locale, languagesOnly: Bool) -> [WhitegramTranslationEntry] {
    var entries: [WhitegramTranslationEntry] = []
    func add(_ id: String, _ section: Int32, _ content: WhitegramTranslationEntry.Content) {
        entries.append(WhitegramTranslationEntry(stableId: id, order: entries.count, section: section, content: content, presentationRevision: state.presentationRevision))
    }
    func title(_ code: String) -> String { return locale.localizedString(forIdentifier: code) ?? code }
    let settings = state.settings
    if let error = state.error { add("error", 0, .info(error)) }

    if languagesOnly {
        add("default", 0, .language(code: "", title: "Automatic", selected: !settings.hasGlobalTarget))
        add("defaultInfo", 0, .info("With Translation uses the device language. If the draft is already in that language, it uses English, or Russian when the device language is English. A chosen global language overrides this. Received messages retain Telegram's per-chat language when automatic translation is off."))
        for code in supportedTranslationLanguages.sorted(by: { title($0).localizedStandardCompare(title($1)) == .orderedAscending }) {
            add("language:\(code)", 1, .language(code: code, title: title(code), selected: WhitegramTranslationSettings.supportedCode(settings.targetLanguage, in: supportedTranslationLanguages) == code))
        }
        return entries
    }

    add("target", 0, .target(settings.hasGlobalTarget ? title(settings.targetLanguage) : "Automatic"))
    if settings.hasGlobalTarget && settings.resolvedTarget(baseLanguage: "", supportedLanguages: supportedTranslationLanguages) == nil {
        add("invalidTarget", 0, .info("The saved language is unsupported. Before-send translation is paused until a supported language or Telegram Default is chosen."))
    }
    add("beforeSend", 0, .beforeSend(settings.beforeSending))
    add("beforeSendInfo", 0, .info("Adds With Translation to the long-press Send menu when Google / Local Translation is enabled. Choosing it translates and sends that text draft. As in the original, a provider failure sends the unchanged draft. Changing the draft or reply, or cancelling, stops the pending action. Normal Send keeps its usual behavior."))
    add("reviewBeforeSend", 0, .reviewBeforeSend(settings.reviewBeforeSending))
    add("reviewBeforeSendInfo", 0, .info("Additional review mode: the first normal Send tap translates a draft with the selected provider; the second sends it after review. This mode is separate from the original With Translation menu action."))

    add("providerHeader", 1, .header("TRANSLATION PROVIDER"))
    for provider in WhiteGramOtherTranslationService.allCases {
        let selected = (settings.localTranslationRequested ? WhiteGramOtherTranslationService.gTranslate : state.native.translationService) == provider && !settings.appleTranslationRequested
        add("provider:\(provider.rawValue)", 1, .provider(provider, selected))
    }
    add("apple", 1, .apple(settings.appleTranslationRequested))
    add("networkInfo", 1, .info("Telegram and Google send text over the network. The original Local Translation setting uses Google, not an offline model. Apple stays on device after language downloads and never falls back to a network provider. Formatting boundaries, code and links are preserved; splitting at formatting boundaries can reduce translation context."))

    add("receivedHeader", 2, .header("RECEIVED MESSAGES"))
    add("automatic", 2, .automatic(state.native.autoTranslate))
    add("button", 2, .button(state.native.translationButton))
    add("nativeSettings", 2, .nativeSettings)
    add("ignoredInfo", 2, .info("Do Not Translate Languages uses Telegram's native settings. Automatic translation skips the chosen target language; the native ignored-language list applies when automatic translation is off."))

    add("availabilityHeader", 3, .header("AVAILABILITY"))
    if #available(iOS 18.0, *) {
        add("localInfo", 3, .info("Apple checks the detected source and selected target with LanguageAvailability. The system asks permission for missing language models. Unsupported pairs and cancellation keep the original text. Rich-message blocks require Telegram's structured API."))
    } else {
        add("localInfo", 3, .info("Apple translation requires iOS 18 or later. A restored Apple selection pauses translation; select Telegram or Google explicitly to continue."))
    }
    add("voice", 3, .voice(settings.voiceTranslationRequested))
    add("voiceInfo", 3, .info(WhitegramLocalization.string("wh.voiceTranslation") + " This original option selects Apple transcription for voice and video notes. With it off, the existing transcription provider settings apply."))
    add("transcripts", 3, .transcripts(settings.translateTranscripts))
    add("transcriptsInfo", 3, .info("Translates completed transcript text into the incoming chat target with the selected text-translation provider. Original audio and transcription text are retained. This is separate from speech recognition."))
    add("siriInfo", 3, .info(WhitegramLocalization.string("transcription.siriPrivacy") + "\nThe notice appears once when Apple transcription starts; dismissal is saved separately."))
    if settings.siriWarningDismissed { add("resetSiri", 3, .resetSiri) }
    return entries
}

private func whitegramTranslationListController(context: AccountContext, coordinator: WhitegramTranslationSettingsCoordinator, languagesOnly: Bool) -> ViewController {
    let signal = combineLatest(context.sharedContext.presentationData, coordinator.state.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let data = ItemListPresentationData(presentationData)
        let controllerState = ItemListControllerState(presentationData: data, title: .text(WhitegramLocalization.string(languagesOnly ? "s.translationTargetLang" : "section.translation", baseLanguage: presentationData.strings.baseLanguageCode)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
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
