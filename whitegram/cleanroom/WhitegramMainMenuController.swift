import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext

private enum WhitegramMainMenuSection: Int32 {
    case about
    case features
    case all
}

private final class WhitegramMainMenuArguments {
    let open: (WhitegramMenuSection) -> Void

    init(open: @escaping (WhitegramMenuSection) -> Void) {
        self.open = open
    }
}

private enum WhitegramMainMenuEntry: ItemListNodeEntry {
    case row(WhitegramMainMenuSection, Int, WhitegramMenuSection, String, String)
    case version(WhitegramMainMenuSection, String)

    var section: ItemListSectionId {
        switch self {
        case let .row(section, _, _, _, _):
            return section.rawValue
        case let .version(section, _):
            return section.rawValue
        }
    }

    var stableId: String {
        switch self {
        case let .row(_, _, item, _, _):
            return "row-\(item.id)"
        case let .version(_, value):
            return "version-\(value)"
        }
    }

    static func ==(lhs: WhitegramMainMenuEntry, rhs: WhitegramMainMenuEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.row(leftSection, leftIndex, leftItem, leftTitle, leftSubtitle), .row(rightSection, rightIndex, rightItem, rightTitle, rightSubtitle)):
            return leftSection == rightSection && leftIndex == rightIndex && leftItem == rightItem && leftTitle == rightTitle && leftSubtitle == rightSubtitle
        case let (.version(leftSection, leftValue), .version(rightSection, rightValue)):
            return leftSection == rightSection && leftValue == rightValue
        default: return false
        }
    }

    static func <(lhs: WhitegramMainMenuEntry, rhs: WhitegramMainMenuEntry) -> Bool {
        if lhs.section != rhs.section { return lhs.section < rhs.section }
        switch (lhs, rhs) {
        case let (.row(_, lhsIndex, _, _, _), .row(_, rhsIndex, _, _, _)): return lhsIndex < rhsIndex
        case (.row, .version): return true
        default: return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        switch self {
        case let .row(_, _, section, title, subtitle):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: section.image(),
                title: title,
                label: "",
                additionalDetailLabel: subtitle.isEmpty ? nil : subtitle,
                sectionId: self.section,
                style: .blocks,
                action: {
                    (arguments as! WhitegramMainMenuArguments).open(section)
                }
            )
        case let .version(_, value):
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain(value),
                sectionId: self.section,
                style: .blocks
            )
        }
    }
}

private let whitegramAboutIds = ["about", "apiStatus", "donate"]

private let whitegramFeatureIds = [
    "search", "appearance", "notifications", "liquidGlass", "messages", "camera", "ghost", "privacy",
    "info", "misc", "interface", "tabs", "localStars", "fonts", "translation", "traffic", "virusTotal",
    "voiceChanger", "player", "radio", "features", "icons", "plugins", "localization", "sessions"
]

private func whitegramSection(id: String) -> WhitegramMenuSection {
    return WhitegramMenuCatalog.sections.first(where: { $0.id == id })
        ?? WhitegramMenuSection(id: id, icon: "questionmark", ruTitle: id, ruDescription: id, enTitle: id, enDescription: id)
}

private func whitegramMainMenuEntries(baseLanguage: String) -> [WhitegramMainMenuEntry] {
    var entries: [WhitegramMainMenuEntry] = []
    let hideDescriptions = WhitegramPreferences.bool("hideSettingsDescriptions", default: UserDefaults.standard.bool(forKey: "wg_hideSettingsDescriptions"))
    func append(_ id: String, to group: WhitegramMainMenuSection) {
        let item = whitegramSection(id: id)
        entries.append(.row(group, entries.count, item, item.title(baseLanguage: baseLanguage), hideDescriptions ? "" : item.description(baseLanguage: baseLanguage)))
    }
    for id in whitegramAboutIds where WhitegramMenuCatalog.implemented.contains(id) {
        append(id, to: .about)
    }
    for id in whitegramFeatureIds where WhitegramMenuCatalog.implemented.contains(id) {
        append(id, to: .features)
    }
    for id in ["publicSettings", "allSettings"] {
        append(id, to: .all)
    }
    let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    entries.append(.version(.all, "Whitegram \(version) (\(build))"))
    return entries
}

public func whitegramMainMenuController(context: AccountContext) -> ViewController {
    WhitegramForkBridge.migrate()
    var pushController: ((ViewController) -> Void)?
    let arguments = WhitegramMainMenuArguments(open: { section in
        let baseLanguage = context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode }
        switch section.id {
        case "about":
            pushController?(whitegramAboutController(context: context, section: section))
        case "ghost", "privacy":
            pushController?(whitegramPrivacySettingsController(context: context))
        case "messages":
            pushController?(whitegramHistoryController(context: context))
        case "fonts":
            pushController?(whitegramFontsController(context: context))
        case "icons":
            pushController?(whitegramIconsController(context: context))
        case "plugins":
            pushController?(whitegramPluginManagerController(context: context))
        case "voiceChanger":
            pushController?(whitegramVoiceSettingsController(context: context))
        case "player":
            pushController?(whitegramPlayerSettingsController(context: context))
        case "liquidGlass":
            pushController?(whitegramGlassController(context: context))
        case "localStars":
            pushController?(whitegramLocalStarsController(context: context))
        case "virusTotal":
            pushController?(whitegramVirusTotalController(context: context))
        case "tabs":
            pushController?(whiteGramTabsSettingsController(context: context))
        case "camera":
            pushController?(whitegramMediaSettingsController(context: context))
        case "translation":
            pushController?(whitegramTranslationSettingsController(context: context))
        case "sessions":
            pushController?(whitegramAccountsSettingsController(context: context))
        case "localization":
            pushController?(whitegramLocalizationController(context: context))
        case "search":
            pushController?(whitegramGeneratedSettingsController(context: context, title: section.title(baseLanguage: baseLanguage), availableOnly: true))
        case "allSettings":
            pushController?(whitegramGeneratedSettingsController(context: context, title: section.title(baseLanguage: baseLanguage)))
        case "publicSettings":
            pushController?(whiteGramSettingsController(context: context))
        default:
            let sections: [String: Set<Int>] = ["appearance": [3, 9], "interface": [5], "info": [6], "misc": [8]]
            if let sections = sections[section.id] {
                pushController?(whitegramGeneratedSettingsController(context: context, sections: sections, title: section.title(baseLanguage: baseLanguage), availableOnly: true))
            }
        }
    })
    let signal = combineLatest(context.sharedContext.presentationData, whitegramLocalizationUpdates())
        |> deliverOnMainQueue
        |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
            WhitegramLocalization.rememberBaseLanguage(presentationData.strings.baseLanguageCode)
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text("Whitegram"),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
                animateChanges: false
            )
            let listState = ItemListNodeState(
                presentationData: ItemListPresentationData(presentationData),
                entries: whitegramMainMenuEntries(baseLanguage: presentationData.strings.baseLanguageCode),
                style: .blocks,
                animateChanges: false
            )
            return (controllerState, (listState, arguments))
        }
    let controller = ItemListController(context: context, state: signal)
    pushController = { [weak controller] inner in
        controller?.navigationController?.pushViewController(inner, animated: true)
    }
    return controller
}

private func whitegramAboutController(context: AccountContext, section: WhitegramMenuSection) -> ViewController {
    let baseLanguage = context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode }
    let russian = WhitegramLocalization.selectedLanguage(baseLanguage: baseLanguage) == "ru"
    let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    return whitegramSimpleInfoController(
        context: context,
        title: section.title(baseLanguage: baseLanguage),
        lines: [
            "Whitegram", "\(version) (\(build))",
            russian ? "База исходников: Telegram 12.9.2" : "Source baseline: Telegram 12.9.2",
            russian ? "Частичный перенос функций Whitegram. Полное соответствие оригиналу не подтверждено." : "Partial Whitegram feature port. Full parity with the original has not been verified."
        ]
    )
}

private struct WhitegramSimpleEntry: ItemListNodeEntry {
    let text: String
    let index: Int

    var section: ItemListSectionId { return 0 }

    var stableId: Int { return self.index }

    static func ==(lhs: WhitegramSimpleEntry, rhs: WhitegramSimpleEntry) -> Bool {
        return lhs.index == rhs.index
    }

    static func <(lhs: WhitegramSimpleEntry, rhs: WhitegramSimpleEntry) -> Bool {
        return lhs.index < rhs.index
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        return ItemListTextItem(
            presentationData: presentationData,
            text: .plain(self.text),
            sectionId: self.section,
            style: .blocks
        )
    }
}

public func whitegramSimpleInfoController(context: AccountContext, title: String, lines: [String]) -> ViewController {
    let signal = context.sharedContext.presentationData
        |> deliverOnMainQueue
        |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let entries: [WhitegramSimpleEntry] = lines.enumerated().map { WhitegramSimpleEntry(text: $1, index: $0) }
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text(title),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
                animateChanges: false
            )
            let listState = ItemListNodeState(
                presentationData: ItemListPresentationData(presentationData),
                entries: entries,
                style: .blocks,
                animateChanges: false
            )
            return (controllerState, (listState, NSNull()))
        }
    return ItemListController(context: context, state: signal)
}
