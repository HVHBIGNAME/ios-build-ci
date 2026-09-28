import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext
import AppBundle

private struct WhitegramIconChoice: Equatable {
    let alternateName: String?
    let title: String
    let previewName: String?
    let assetName: String?
    let files: [String]

    var id: String {
        return self.alternateName.map { "alternate:" + $0 } ?? "primary"
    }
}

private func whitegramBundledIcons(context: AccountContext) -> [WhitegramIconChoice] {
    let info = Bundle.main.infoDictionary ?? [:]
    let phoneIcons = (info["CFBundleIcons"] as? [String: Any]) ?? [:]
    let deviceIcons: [String: Any]
    if UIDevice.current.userInterfaceIdiom == .pad {
        deviceIcons = (info["CFBundleIcons~ipad"] as? [String: Any]) ?? phoneIcons
    } else {
        deviceIcons = phoneIcons
    }
    let primary = (deviceIcons["CFBundlePrimaryIcon"] as? [String: Any]) ?? (phoneIcons["CFBundlePrimaryIcon"] as? [String: Any]) ?? [:]
    let alternates = (deviceIcons["CFBundleAlternateIcons"] as? [String: [String: Any]]) ?? [:]
    let bindings = context.sharedContext.applicationBindings.getAvailableAlternateIcons()
    var choices = [WhitegramIconChoice(
        alternateName: nil,
        title: "Default",
        previewName: bindings.first(where: { $0.isDefault })?.imageName,
        assetName: primary["CFBundleIconName"] as? String,
        files: (primary["CFBundleIconFiles"] as? [String]) ?? []
    )]
    // Bindings supply previews, but only the built device-specific plist authorizes a name.
    for name in alternates.keys.sorted() {
        guard let metadata = alternates[name] else {
            continue
        }
        let files = (metadata["CFBundleIconFiles"] as? [String]) ?? []
        let assetName = metadata["CFBundleIconName"] as? String
        guard !files.isEmpty || assetName != nil else {
            continue
        }
        choices.append(WhitegramIconChoice(alternateName: name, title: name, previewName: bindings.first(where: { $0.name == name && !$0.isDefault })?.imageName, assetName: assetName, files: files))
    }
    return choices
}

private func whitegramIconPreview(_ choice: WhitegramIconChoice) -> UIImage? {
    var image: UIImage?
    let names = choice.files + [choice.assetName].compactMap { $0 }
    for name in names {
        if let candidate = UIImage(named: name, in: Bundle.main, compatibleWith: nil) {
            image = candidate
            break
        }
    }
    if image == nil, let name = choice.previewName {
        image = UIImage(named: name, in: getAppBundle(), compatibleWith: nil)
    }
    guard let source = image else {
        return nil
    }
    let size = CGSize(width: 40.0, height: 40.0)
    return UIGraphicsImageRenderer(size: size).image { _ in
        let rect = CGRect(origin: .zero, size: size)
        UIBezierPath(roundedRect: rect, cornerRadius: 9.0).addClip()
        source.draw(in: rect)
    }
}

private struct WhitegramIconsState: Equatable {
    var choices: [WhitegramIconChoice] = []
    var currentName: String?
    var supported = false
    var busy = false
    var status: String?
}

private enum WhitegramIconEntry: ItemListNodeEntry {
    case icon(Int, WhitegramIconChoice, Bool, Bool)
    case info(String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: String {
        switch self {
        case let .icon(_, choice, _, _):
            return choice.id
        case .info:
            return "info"
        }
    }

    private var order: Int {
        switch self {
        case let .icon(index, _, _, _):
            return index
        case .info:
            return Int.max
        }
    }

    static func < (lhs: WhitegramIconEntry, rhs: WhitegramIconEntry) -> Bool {
        return lhs.order < rhs.order
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! WhitegramIconsCoordinator
        switch self {
        case let .icon(_, choice, selected, enabled):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, icon: whitegramIconPreview(choice), iconSize: CGSize(width: 40.0, height: 40.0), title: choice.title, subtitle: selected ? "Current app icon" : nil, style: .right, checked: selected, enabled: enabled, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.select(choice)
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

private func whitegramIconEntries(_ state: WhitegramIconsState) -> [WhitegramIconEntry] {
    var entries = state.choices.enumerated().map { index, choice in
        WhitegramIconEntry.icon(index, choice, choice.alternateName == state.currentName, state.supported && !state.busy)
    }
    var information = "Choose one of the app icons bundled with this build. iOS may display a confirmation after applying the change."
    if !state.supported {
        information = "This application or device does not support alternate app icons."
    } else if state.choices.count == 1 {
        information = "This build has no alternate icons in its device-specific Info.plist."
    }
    if let currentName = state.currentName, !state.choices.contains(where: { $0.alternateName == currentName }) {
        information += "\nCurrent icon: \(currentName). Its entry is not available in this build; choose Default to reset it."
    }
    if let status = state.status {
        information += "\n\n" + status
    }
    entries.append(.info(information))
    return entries
}

private final class WhitegramIconsCoordinator {
    let context: AccountContext
    let state = ValuePromise(WhitegramIconsState(), ignoreRepeated: true)
    private var observer: NSObjectProtocol?
    private var busy = false
    private var status: String?

    init(context: AccountContext) {
        self.context = context
        self.observer = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.refresh()
        })
        self.refresh()
    }

    deinit {
        if let observer = self.observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func refresh() {
        let isMainApp = self.context.sharedContext.applicationBindings.isMainApp
        let currentName = isMainApp ? UIApplication.shared.alternateIconName : self.context.sharedContext.applicationBindings.getAlternateIconName()
        self.state.set(WhitegramIconsState(choices: whitegramBundledIcons(context: self.context), currentName: currentName, supported: isMainApp && UIApplication.shared.supportsAlternateIcons, busy: self.busy, status: self.status))
    }

    func select(_ choice: WhitegramIconChoice) {
        guard !self.busy, self.context.sharedContext.applicationBindings.isMainApp else {
            return
        }
        let application = UIApplication.shared
        guard application.supportsAlternateIcons else {
            self.status = "iOS reports that alternate app icons are unavailable."
            self.refresh()
            return
        }
        guard whitegramBundledIcons(context: self.context).contains(where: { $0.alternateName == choice.alternateName }) else {
            self.status = "This icon is not declared in the installed app bundle."
            self.refresh()
            return
        }
        guard application.alternateIconName != choice.alternateName else {
            self.status = "\(choice.title) is already the current app icon."
            self.refresh()
            return
        }
        self.busy = true
        self.status = "Changing app icon…"
        self.refresh()
        // Use UIKit directly: the bindings' Bool completion discards the actual error.
        application.setAlternateIconName(choice.alternateName, completionHandler: { error in
            DispatchQueue.main.async {
                self.busy = false
                let actualName = application.alternateIconName
                if let error = error {
                    self.status = "Icon change was not completed: \(error.localizedDescription)"
                } else if actualName != choice.alternateName {
                    self.status = "iOS did not activate the requested icon. The checkmark shows the current system value."
                } else if WhitegramPreferences.set(actualName ?? "", for: "appIconName") {
                    self.status = "\(choice.title) is now the app icon."
                } else {
                    self.status = "iOS changed the app icon, but Whitegram could not save its settings mirror."
                }
                self.refresh()
            }
        })
    }
}

public func whitegramIconsController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramIconsCoordinator(context: context)
    let signal = combineLatest(context.sharedContext.presentationData, coordinator.state.get())
        |> deliverOnMainQueue
        |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let data = ItemListPresentationData(presentationData)
            let controllerState = ItemListControllerState(presentationData: data, title: .text("App Icons"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
            let listState = ItemListNodeState(presentationData: data, entries: whitegramIconEntries(state), style: .blocks, animateChanges: false)
            return (controllerState, (listState, coordinator))
        }
    let controller = ItemListController(context: context, state: signal)
    controller.didAppear = { [coordinator] _ in
        coordinator.refresh()
    }
    return controller
}
