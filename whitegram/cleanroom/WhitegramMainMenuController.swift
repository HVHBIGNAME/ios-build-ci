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
    case row(WhitegramMainMenuSection, Int, WhitegramMenuSection)
    case version(WhitegramMainMenuSection, String)

    var section: ItemListSectionId {
        switch self {
        case let .row(section, _, _):
            return section.rawValue
        case let .version(section, _):
            return section.rawValue
        }
    }

    var stableId: String {
        switch self {
        case let .row(_, _, item):
            return "row-\(item.id)"
        case let .version(_, value):
            return "version-\(value)"
        }
    }

    static func ==(lhs: WhitegramMainMenuEntry, rhs: WhitegramMainMenuEntry) -> Bool {
        return lhs.stableId == rhs.stableId && lhs.section == rhs.section
    }

    static func <(lhs: WhitegramMainMenuEntry, rhs: WhitegramMainMenuEntry) -> Bool {
        if lhs.section != rhs.section { return lhs.section < rhs.section }
        switch (lhs, rhs) {
        case let (.row(_, lhsIndex, _), .row(_, rhsIndex, _)): return lhsIndex < rhsIndex
        case (.row, .version): return true
        default: return false
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let russian = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        switch self {
        case let .row(_, _, section):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                icon: section.image(),
                title: section.title(russian: russian),
                label: section.description(russian: russian),
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
    "info", "misc", "interface", "tabs", "localStars", "fonts", "translation", "ai", "traffic", "virusTotal",
    "voiceChanger", "player", "radio", "features", "icons", "plugins", "localization", "sessions"
]

private func whitegramSection(id: String) -> WhitegramMenuSection {
    return WhitegramMenuCatalog.sections.first(where: { $0.id == id })
        ?? WhitegramMenuSection(id: id, icon: "questionmark", ruTitle: id, ruDescription: id, enTitle: id, enDescription: id)
}

private func whitegramMainMenuEntries(russian: Bool) -> [WhitegramMainMenuEntry] {
    var entries: [WhitegramMainMenuEntry] = []
    for id in whitegramAboutIds where WhitegramMenuCatalog.implemented.contains(id) {
        entries.append(.row(.about, entries.count, whitegramSection(id: id)))
    }
    for id in whitegramFeatureIds where WhitegramMenuCatalog.implemented.contains(id) {
        entries.append(.row(.features, entries.count, whitegramSection(id: id)))
    }
    for id in ["publicSettings", "allSettings"] {
        entries.append(.row(.all, entries.count, whitegramSection(id: id)))
    }
    let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    entries.append(.version(.all, russian ? "\(version) (\(build))" : "Whitegram \(version) (\(build))"))
    return entries
}

public func whitegramMainMenuController(context: AccountContext) -> ViewController {
    WhitegramForkBridge.migrate()
    var pushController: ((ViewController) -> Void)?
    let arguments = WhitegramMainMenuArguments(open: { section in
        let russian = context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode.hasPrefix("ru") }
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
        case "ai":
            pushController?(whitegramAISettingsController(context: context))
        case "virusTotal":
            pushController?(whitegramVirusTotalController(context: context))
        case "tabs":
            pushController?(whiteGramTabsSettingsController(context: context))
        case "camera":
            pushController?(whiteGramChatSettingsController(context: context))
        case "translation":
            pushController?(whiteGramOtherSettingsController(context: context))
        case "sessions":
            pushController?(whitegramAccountsSettingsController(context: context))
        case "search":
            pushController?(whitegramGeneratedSettingsController(context: context, title: section.title(russian: russian), availableOnly: true))
        case "allSettings":
            pushController?(whitegramGeneratedSettingsController(context: context, title: section.title(russian: russian)))
        case "publicSettings":
            pushController?(whiteGramSettingsController(context: context))
        default:
            let sections: [String: Set<Int>] = ["appearance": [3, 9], "interface": [5], "info": [6], "misc": [8]]
            if let sections = sections[section.id] {
                pushController?(whitegramGeneratedSettingsController(context: context, sections: sections, title: section.title(russian: russian), availableOnly: true))
            }
        }
    })
    let signal = context.sharedContext.presentationData
        |> deliverOnMainQueue
        |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let russian = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
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
                entries: whitegramMainMenuEntries(russian: russian),
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
    let russian = context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode.hasPrefix("ru") }
    let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "—"
    return whitegramSimpleInfoController(
        context: context,
        title: section.title(russian: russian),
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
