import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
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
    case row(WhitegramMainMenuSection, WhitegramMenuSection)
    case version(WhitegramMainMenuSection, String)

    var section: ItemListSectionId {
        switch self {
        case let .row(section, _):
            return section.rawValue
        case let .version(section, _):
            return section.rawValue
        }
    }

    var stableId: String {
        switch self {
        case let .row(_, item):
            return "row-\(item.id)"
        case let .version(_, value):
            return "version-\(value)"
        }
    }

    static func ==(lhs: WhitegramMainMenuEntry, rhs: WhitegramMainMenuEntry) -> Bool {
        return lhs.stableId == rhs.stableId && lhs.section == rhs.section
    }

    static func <(lhs: WhitegramMainMenuEntry, rhs: WhitegramMainMenuEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let russian = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        switch self {
        case let .row(_, section):
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
                text: value,
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

private func whitegramMainMenuEntries(russian: Bool) -> [WhitegramMainMenuEntry] {
    var entries: [WhitegramMainMenuEntry] = []
    for id in whitegramAboutIds {
        entries.append(.row(.about, whitegramSection(id: id)))
    }
    for id in whitegramFeatureIds {
        entries.append(.row(.features, whitegramSection(id: id)))
    }
    entries.append(.row(.all, whitegramSection(id: "allSettings")))
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    entries.append(.version(.all, russian ? "\(version) (\(build))" : "Whitegram \(version) (\(build))"))
    return entries
}

public func whitegramMainMenuController(context: AccountContext) -> ViewController {
    var pushController: ((ViewController) -> Void)?
    let arguments = WhitegramMainMenuArguments(open: { section in
        switch section.id {
        case "about":
            pushController?(whitegramAboutController(context: context, section: section))
        case "privacy":
            pushController?(whitegramPrivacySettingsController(context: context))
        case "allSettings":
            pushController?(whitegramSimpleInfoController(
                context: context,
                title: section.enTitle,
                lines: WhitegramMenuCatalog.sections.map { "\($0.enTitle) — \($0.enDescription)" }
            ))
        default:
            pushController?(whitegramNotPortedController(context: context, section: section))
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
        controller?.push(inner, in: .root, with: .animation(fast: true))
    }
    return controller
}

private func whitegramAboutController(context: AccountContext, section: WhitegramMenuSection) -> ViewController {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    return whitegramSimpleInfoController(
        context: context,
        title: section.enTitle,
        lines: ["Whitegram", "\(version) (\(build))", section.ruDescription, section.enDescription]
    )
}

private func whitegramNotPortedController(context: AccountContext, section: WhitegramMenuSection) -> ViewController {
    return whitegramSimpleInfoController(
        context: context,
        title: section.enTitle,
        lines: [section.ruDescription, section.enDescription]
    )
}

private struct WhitegramSimpleEntry: ItemListNodeEntry {
    let text: String
    let index: Int

    var section: ItemListSectionId { return 0 }

    var stableId: Int { return self.index }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        return ItemListTextItem(
            presentationData: presentationData,
            text: self.text,
            sectionId: self.section,
            style: .blocks
        )
    }
}

public func whitegramSimpleInfoController(context: AccountContext, title: String, lines: [String]) -> ViewController {
    let signal = context.sharedContext.presentationData
        |> deliverOnMainQueue
        |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let entries: [ItemListNodeEntry] = lines.enumerated().map { WhitegramSimpleEntry(text: $1, index: $0) }
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
            return (controllerState, (listState, ()))
        }
    return ItemListController(context: context, state: signal)
}
