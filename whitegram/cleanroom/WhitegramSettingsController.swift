import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import AccountContext

private final class WhitegramSettingsControllerArguments {
    let setBool: (String, Bool) -> Void
    let open: (String) -> Void

    init(setBool: @escaping (String, Bool) -> Void, open: @escaping (String) -> Void) {
        self.setBool = setBool
        self.open = open
    }
}

private enum WhitegramSettingsRow: ItemListNodeEntry {
    case row(WhitegramSettingsRowDescriptor)

    var descriptor: WhitegramSettingsRowDescriptor {
        switch self {
        case let .row(descriptor):
            return descriptor
        }
    }

    var section: ItemListSectionId {
        return Int32(self.descriptor.section)
    }

    var stableId: String {
        return self.descriptor.id
    }

    static func ==(lhs: WhitegramSettingsRow, rhs: WhitegramSettingsRow) -> Bool {
        return lhs.descriptor.id == rhs.descriptor.id && lhs.section == rhs.section
    }

    static func <(lhs: WhitegramSettingsRow, rhs: WhitegramSettingsRow) -> Bool {
        if lhs.section != rhs.section {
            return lhs.section < rhs.section
        }
        return lhs.descriptor.order < rhs.descriptor.order
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! WhitegramSettingsControllerArguments
        let descriptor = self.descriptor
        let value = WhitegramSettingsState.current.boolValue(for: descriptor.id) ?? false
        switch descriptor.kind {
        case .headerRow:
            return ItemListSectionHeaderItem(presentationData: presentationData, text: descriptor.title, sectionId: self.section)
        case .switchRow, .checkboxRow:
            return ItemListSwitchItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: descriptor.title,
                text: nil,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { updated in arguments.setBool(descriptor.id, updated) }
            )
        case .actionRow, .linkRow:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: descriptor.title,
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: { arguments.open(descriptor.id) }
            )
        case .disclosureRow, .segmentedRow, .sliderRow, .textRow, .valueRow:
            return ItemListDisclosureItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: descriptor.title,
                label: descriptor.labelsVerified ? (value ? "on" : "off") : "not ported",
                sectionId: self.section,
                style: .blocks,
                action: { arguments.open(descriptor.id) }
            )
        }
    }
}

public func whitegramSettingsController(context: AccountContext) -> ViewController {
    let promise = ValuePromise(WhitegramSettingsState.current, ignoreRepeated: true)
    var pushController: ((ViewController) -> Void)?
    let arguments = WhitegramSettingsControllerArguments(
        setBool: { id, value in
            var state = WhitegramSettingsState.current
            state.setBool(value, for: id)
            state.save()
            promise.set(state)
        },
        open: { id in
            pushController?(whitegramNotPortedController(context: context, id: id))
        }
    )
    let signal = combineLatest(context.sharedContext.presentationData, promise.get())
        |> deliverOnMainQueue
        |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
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
                entries: WhitegramSettingsCatalog.rows.map { WhitegramSettingsRow.row($0) },
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
