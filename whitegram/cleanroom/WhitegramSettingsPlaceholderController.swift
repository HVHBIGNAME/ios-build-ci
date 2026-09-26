import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import AccountContext

/// Shown for every row whose behaviour is not ported yet, so the menu never
/// pretends a feature works when it does not.
public func whitegramNotPortedController(context: AccountContext, id: String) -> ViewController {
    let title = WhitegramSettingsCatalog.rows.first(where: { $0.id == id })?.title ?? id
    let signal = context.sharedContext.presentationData
        |> deliverOnMainQueue
        |> map { presentationData -> (ItemListControllerState, (ItemListNodeState, Any)) in
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
                entries: [WhitegramPlaceholderEntry(text: id)],
                style: .blocks,
                animateChanges: false
            )
            return (controllerState, (listState, ()))
        }
    return ItemListController(context: context, state: signal)
}

private struct WhitegramPlaceholderEntry: ItemListNodeEntry {
    let text: String

    var section: ItemListSectionId { return 0 }

    var stableId: String { return self.text }

    static func ==(lhs: WhitegramPlaceholderEntry, rhs: WhitegramPlaceholderEntry) -> Bool {
        return lhs.text == rhs.text
    }

    static func <(lhs: WhitegramPlaceholderEntry, rhs: WhitegramPlaceholderEntry) -> Bool {
        return lhs.text < rhs.text
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        return ItemListTextItem(presentationData: presentationData, text: .plain(self.text), sectionId: self.section, style: .blocks)
    }
}
