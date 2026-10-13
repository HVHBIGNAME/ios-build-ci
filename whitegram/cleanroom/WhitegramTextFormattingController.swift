import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext

private final class WhitegramTextFormattingState {
    let updates = ValuePromise<Int>(0, ignoreRepeated: true)
    weak var controller: ViewController?
    private var revision = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        for name in [WhitegramPreferences.updatedNotification, WhitegramLocalizationStore.changedNotification] {
            self.observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.changed()
            })
        }
    }

    deinit {
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func changed() {
        self.revision += 1
        self.updates.set(self.revision)
    }

    func select(_ value: Int) {
        guard let changes = WhitegramTextSettings.selectionChanges(value) else { return }
        self.save(changes)
    }

    func setSendOnReturn(_ value: Bool) {
        self.save(["sendOnReturnKey": value])
    }

    private func save(_ changes: [String: Any]) {
        if !WhitegramPreferences.update(changes) {
            let alert = UIAlertController(title: "Whitegram", message: WhitegramComposerStrings.string("composer.saveFailed"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self.controller?.present(alert, animated: true)
        }
        self.changed()
    }
}

private struct WhitegramTextFormattingEntry: ItemListNodeEntry {
    let index: Int
    let title: String
    let selected: Bool
    var section: ItemListSectionId { return self.index == 0 ? 0 : 1 }
    var stableId: Int { return self.index }
    static func ==(lhs: Self, rhs: Self) -> Bool { return lhs.index == rhs.index && lhs.title == rhs.title && lhs.selected == rhs.selected }
    static func <(lhs: Self, rhs: Self) -> Bool { return lhs.index < rhs.index }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let state = arguments as! WhitegramTextFormattingState
        if self.index == 0 {
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: self.title,
                value: self.selected, sectionId: self.section, style: .blocks, updated: { state.setSendOnReturn($0) })
        }
        return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: self.title,
            style: .right, checked: self.selected, zeroSeparatorInsets: false, sectionId: self.section,
            action: { state.select(self.index - 1) })
    }
}

public func whitegramTextFormattingController(context: AccountContext) -> ViewController {
    let state = WhitegramTextFormattingState()
    let keys = ["fmt.off", "fmt.bold", "fmt.italic", "fmt.mono", "fmt.strike", "fmt.spoiler", "fmt.mixedScript", "fmt.mixedScriptUppercase"]
    let signal = combineLatest(context.sharedContext.presentationData, state.updates.get())
    |> deliverOnMainQueue
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let selected = WhitegramTextSettings.current.selection
        var rows = [WhitegramTextFormattingEntry(index: 0,
            title: WhitegramComposerStrings.string("composer.sendOnReturn", baseLanguage: presentationData.strings.baseLanguageCode),
            selected: WhitegramTextSettings.current.sendOnReturnKey)]
        rows += keys.enumerated().map { index, key in
            WhitegramTextFormattingEntry(index: index + 1, title: WhitegramLocalization.string(key, baseLanguage: presentationData.strings.baseLanguageCode), selected: selected == index)
        }
        let controller = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(WhitegramLocalization.string("s.autoFormat", baseLanguage: presentationData.strings.baseLanguageCode)), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        return (controller, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: rows, style: .blocks, animateChanges: false), state))
    }
    let controller = ItemListController(context: context, state: signal)
    state.controller = controller
    return controller
}
