import Foundation
import UIKit
import Display
import Postbox
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import AccountContext

private final class WhitegramAccountsArguments {
    let switchAccount: (AccountRecordId) -> Void
    let addAccount: () -> Void

    init(switchAccount: @escaping (AccountRecordId) -> Void, addAccount: @escaping () -> Void) {
        self.switchAccount = switchAccount
        self.addAccount = addAccount
    }
}

private enum WhitegramAccountsSection: Int32 {
    case accounts
    case actions
}

private enum WhitegramAccountsEntry: ItemListNodeEntry {
    case account(AccountRecordId, Bool)
    case addAccount

    var section: ItemListSectionId {
        switch self {
        case .account:
            return WhitegramAccountsSection.accounts.rawValue
        case .addAccount:
            return WhitegramAccountsSection.actions.rawValue
        }
    }

    var stableId: Int64 {
        switch self {
        case let .account(id, _):
            return id.int64
        case .addAccount:
            return Int64.max
        }
    }

    static func ==(lhs: WhitegramAccountsEntry, rhs: WhitegramAccountsEntry) -> Bool {
        switch lhs {
        case let .account(lhsId, lhsCurrent):
            if case let .account(rhsId, rhsCurrent) = rhs {
                return lhsId == rhsId && lhsCurrent == rhsCurrent
            }
            return false
        case .addAccount:
            if case .addAccount = rhs {
                return true
            }
            return false
        }
    }

    static func <(lhs: WhitegramAccountsEntry, rhs: WhitegramAccountsEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! WhitegramAccountsArguments
        switch self {
        case let .account(id, current):
            return ItemListCheckboxItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "\(UInt64(bitPattern: id.int64))",
                style: .left,
                checked: current,
                zeroSeparatorInsets: false,
                sectionId: self.section,
                action: {
                    arguments.switchAccount(id)
                }
            )
        case .addAccount:
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Add Account",
                kind: .generic,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.addAccount()
                }
            )
        }
    }
}

private func whitegramAccountsEntries(view: AccountRecordsView<TelegramAccountManagerTypes>) -> [WhitegramAccountsEntry] {
    var entries = view.records.sorted(by: { $0.id < $1.id }).map { record in
        WhitegramAccountsEntry.account(record.id, record.id == view.currentRecord?.id)
    }
    entries.append(.addAccount)
    return entries
}

public func whitegramAccountsSettingsController(context: AccountContext) -> ViewController {
    let accountManager = context.sharedContext.accountManager
    let arguments = WhitegramAccountsArguments(
        switchAccount: { id in
            let _ = accountManager.transaction { transaction in
                transaction.setCurrentId(id)
            }.start()
        },
        addAccount: {
            context.sharedContext.beginNewAuth(testingEnvironment: false)
        }
    )
    let signal = combineLatest(context.sharedContext.presentationData, accountManager.accountRecords())
        |> deliverOnMainQueue
        |> map { presentationData, view -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let controllerState = ItemListControllerState(
                presentationData: ItemListPresentationData(presentationData),
                title: .text("Accounts"),
                leftNavigationButton: nil,
                rightNavigationButton: nil,
                backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
                animateChanges: false
            )
            let listState = ItemListNodeState(
                presentationData: ItemListPresentationData(presentationData),
                entries: whitegramAccountsEntries(view: view),
                style: .blocks,
                animateChanges: true
            )
            return (controllerState, (listState, arguments))
        }
    return ItemListController(context: context, state: signal)
}
