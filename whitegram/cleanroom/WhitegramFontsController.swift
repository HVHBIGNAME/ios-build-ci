import Foundation
import UIKit
import UniformTypeIdentifiers
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import PresentationDataUtils
import ItemListUI
import AccountContext

private struct WhitegramFontListRow: Equatable {
    let font: WhitegramFontRecord
    let available: Bool
}

private struct WhitegramFontsState: Equatable {
    var enabled = false
    var selectedName = ""
    var selectedAvailable = false
    var fonts: [WhitegramFontListRow] = []
    var busy = false
    var status: String?
    var warnings: [String] = []
    var revision = 0
}

private enum WhitegramFontAction: String {
    case choose
    case importFile
    case reset

    var title: String {
        switch self {
        case .choose:
            return "Choose a System Font"
        case .importFile:
            return "Import a TTF or OTF File"
        case .reset:
            return "Reset to System Font"
        }
    }
}

private struct WhitegramFontEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case enabled(Bool, Bool)
        case preview(String, Int)
        case action(WhitegramFontAction, Bool)
        case header(String)
        case info(String)
        case font(WhitegramFontListRow, Bool, Bool)
    }

    let stableId: String
    let order: Int
    let section: ItemListSectionId
    let content: Content

    static func < (lhs: WhitegramFontEntry, rhs: WhitegramFontEntry) -> Bool {
        return lhs.order < rhs.order
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! WhitegramFontsCoordinator
        switch self.content {
        case let .enabled(value, interactive):
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: "Use Custom Font", value: value, enabled: interactive, sectionId: self.section, style: .blocks, updated: { value in
                arguments.setEnabled(value)
            })
        case let .preview(name, _):
            let font = WhitegramFontRegistry.shared.previewFont(named: name, size: 22.0) ?? UIFont.systemFont(ofSize: 22.0)
            let sample = NSAttributedString(string: "The quick brown fox jumps over the lazy dog.\nAa Бб Вв · 0123456789", attributes: [.font: font, .foregroundColor: presentationData.theme.list.itemPrimaryTextColor])
            return ItemListTextItem(presentationData: presentationData, text: .custom(context: arguments.context, string: sample), sectionId: self.section)
        case let .action(action, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: action.title, kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                if enabled {
                    arguments.perform(action)
                }
            })
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .font(row, selected, enabled):
            let source = row.font.fileName == nil ? "System font" : "Imported font"
            let subtitle = row.available ? source + " · " + row.font.name : "Unavailable — swipe to remove or import the file again"
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: row.font.displayName, subtitle: subtitle, style: .right, checked: selected, enabled: enabled, zeroSeparatorInsets: false, sectionId: self.section, action: {
                arguments.select(row.font)
            }, deleteAction: {
                arguments.requestDelete(row.font)
            })
        }
    }
}

private func whitegramFontEntries(_ state: WhitegramFontsState) -> [WhitegramFontEntry] {
    var entries: [WhitegramFontEntry] = []
    func add(_ id: String, _ section: Int32, _ content: WhitegramFontEntry.Content) {
        entries.append(WhitegramFontEntry(stableId: id, order: entries.count, section: section, content: content))
    }
    add("enabled", 0, .enabled(state.enabled, !state.busy && (state.enabled || state.selectedAvailable)))
    let selection: String
    if state.selectedName.isEmpty {
        selection = "System font is active. Choose or import a font to enable a custom face."
    } else if !state.selectedAvailable {
        selection = "\(state.selectedName) is unavailable. Whitegram is using the system font; choose another font or import the missing file."
    } else {
        selection = "Selected: \(state.selectedName)" + (state.enabled ? "" : " (custom fonts are off)")
    }
    add("selection", 0, .info(selection))
    add("preview", 0, .preview(state.selectedName, state.revision))
    add("renderingInfo", 0, .info("Preview of the selected face. Changes apply to newly rendered text using Whitegram’s general font helpers; reopen an existing screen to refresh it. Monospaced, camera, tabular-number and specialized-width requests keep their original fonts."))
    var canPick = false
    if #available(iOS 13.0, *) {
        canPick = true
    }
    add("choose", 1, .action(.choose, canPick && !state.busy))
    add("import", 1, .action(.importFile, !state.busy))
    add("reset", 1, .action(.reset, !state.busy && (state.enabled || !state.selectedName.isEmpty)))
    if let status = state.status {
        add("status", 1, .info(status))
    }
    if !state.warnings.isEmpty {
        add("warnings", 1, .info(state.warnings.joined(separator: "\n")))
    }
    add("historyHeader", 2, .header("SAVED FONTS"))
    for row in state.fonts {
        add("font:" + row.font.name, 2, .font(row, state.selectedName == row.font.name, !state.busy))
    }
    add("historyInfo", 2, .info(state.fonts.isEmpty ? "Your chosen and imported fonts will appear here. Imported files are stored on this device and restored when Whitegram launches." : "Tap a font to use it. Swipe left to remove it from this list. Removing an imported font deletes its file and all faces in that file. Reset restores the system font and keeps this library."))
    return entries
}

private func whitegramFontHistory() -> [[String: String]] {
    return WhitegramPreferences.values()["fontHistory"] as? [[String: String]] ?? []
}

private func whitegramFontHistoryValue(_ font: WhitegramFontRecord) -> [String: String] {
    var value = ["name": font.name, "displayName": font.displayName, "source": font.fileName == nil ? "system" : "import"]
    if let fileName = font.fileName {
        value["fileName"] = fileName
    }
    return value
}

private func whitegramReadFont(_ url: URL) throws -> [WhitegramFontRecord] {
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
        if scoped {
            url.stopAccessingSecurityScopedResource()
        }
    }
    var coordinationError: NSError?
    var result: Result<[WhitegramFontRecord], Error>?
    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError, byAccessor: { coordinatedURL in
        result = Result { try WhitegramFontRegistry.shared.importFont(from: coordinatedURL) }
    })
    if let coordinationError = coordinationError {
        throw coordinationError
    }
    guard let result = result else {
        throw NSError(domain: "WhitegramFonts", code: 1, userInfo: [NSLocalizedDescriptionKey: "The file provider did not supply a readable font file."])
    }
    return try result.get()
}

private final class WhitegramFontsCoordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    let context: AccountContext
    let state = ValuePromise(WhitegramFontsState(), ignoreRepeated: true)
    weak var controller: ItemListController?
    private let workQueue = DispatchQueue(label: "Whitegram.FontImport", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []
    private var nativeController: UIViewController?
    private var busy = false
    private var status: String?

    init(context: AccountContext) {
        self.context = context
        super.init()
        self.observers.append(NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main, using: { [weak self] _ in
            WhitegramFontRegistry.shared.invalidateCache()
            self?.refresh()
        }))
        self.observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: { [weak self] _ in
            WhitegramFontRegistry.shared.invalidateCache()
            self?.refresh()
        }))
        self.refresh()
    }

    deinit {
        for observer in self.observers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let nativeController = self.nativeController {
            DispatchQueue.main.async {
                nativeController.dismiss(animated: false, completion: nil)
            }
        }
    }

    func refresh() {
        let library = WhitegramFontRegistry.shared.library()
        let selectedName = WhitegramPreferences.string("customFontName")
        var imported: [String: WhitegramFontRecord] = [:]
        for font in library.fonts {
            imported[font.name] = font
        }
        var fonts: [WhitegramFontRecord] = []
        var names = Set<String>()
        for value in whitegramFontHistory() {
            guard let name = value["name"], !name.isEmpty, names.insert(name).inserted else {
                continue
            }
            let fileName = value["fileName"].flatMap { $0.isEmpty ? nil : $0 }
            fonts.append(imported[name] ?? WhitegramFontRecord(name: name, displayName: value["displayName"] ?? name, fileName: fileName))
        }
        for font in library.fonts where names.insert(font.name).inserted {
            fonts.append(font)
        }
        if !selectedName.isEmpty, names.insert(selectedName).inserted {
            fonts.insert(WhitegramFontRecord(name: selectedName, displayName: selectedName), at: 0)
        }
        let rows = fonts.map { WhitegramFontListRow(font: $0, available: WhitegramFontRegistry.shared.previewFont(named: $0.name, size: 16.0) != nil) }
        self.state.set(WhitegramFontsState(enabled: WhitegramPreferences.bool("customFontEnabled"), selectedName: selectedName, selectedAvailable: rows.contains(where: { $0.font.name == selectedName && $0.available }), fonts: rows, busy: self.busy || self.nativeController != nil, status: self.status, warnings: library.warnings, revision: library.revision))
    }

    private func save(_ changes: [String: Any], success: String) {
        if WhitegramPreferences.update(changes) {
            self.status = success
        } else {
            self.status = "Could not save font settings. Please try again."
        }
        WhitegramFontRegistry.shared.invalidateCache()
        self.refresh()
    }

    func setEnabled(_ value: Bool) {
        guard !self.busy, self.nativeController == nil else {
            return
        }
        if value && WhitegramFontRegistry.shared.previewFont(named: WhitegramPreferences.string("customFontName"), size: 16.0) == nil {
            self.status = "Choose an available font first."
            self.refresh()
            return
        }
        self.save(["customFontEnabled": value, "customFontName": WhitegramPreferences.string("customFontName")], success: value ? "Custom font enabled." : "System font restored.")
    }

    func select(_ font: WhitegramFontRecord) {
        guard !self.busy, self.nativeController == nil else {
            return
        }
        guard WhitegramFontRegistry.shared.previewFont(named: font.name, size: 16.0) != nil else {
            self.status = "This font is unavailable. Import its file again or choose an installed font."
            self.refresh()
            return
        }
        var history = whitegramFontHistory().filter { $0["name"] != font.name }
        history.insert(whitegramFontHistoryValue(font), at: 0)
        self.save(["customFontEnabled": true, "customFontName": font.name, "fontHistory": history], success: "Selected \(font.displayName).")
    }

    func perform(_ action: WhitegramFontAction) {
        guard !self.busy, self.nativeController == nil else {
            return
        }
        switch action {
        case .choose:
            if #available(iOS 13.0, *) {
                let configuration = UIFontPickerViewController.Configuration()
                configuration.includeFaces = true
                let picker = UIFontPickerViewController(configuration: configuration)
                picker.delegate = self
                picker.modalPresentationStyle = .formSheet
                self.presentNative(picker)
            } else {
                self.status = "The system font picker requires iOS 13 or later. You can still import a font file."
                self.refresh()
            }
        case .importFile:
            let picker: UIDocumentPickerViewController
            if #available(iOS 14.0, *) {
                picker = UIDocumentPickerViewController(forOpeningContentTypes: [.font], asCopy: true)
            } else {
                picker = UIDocumentPickerViewController(documentTypes: ["public.font"], in: .import)
            }
            picker.allowsMultipleSelection = false
            picker.delegate = self
            picker.modalPresentationStyle = .formSheet
            self.presentNative(picker)
        case .reset:
            self.save(["customFontEnabled": false, "customFontName": ""], success: "System font restored. Your saved fonts are still available below.")
        }
    }

    private func presentNative(_ nativeController: UIViewController) {
        guard var presenter = self.controller?.viewIfLoaded?.window?.rootViewController else {
            self.status = "The font screen is not ready to present a picker. Please try again."
            self.refresh()
            return
        }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        guard !presenter.isBeingDismissed, !presenter.isBeingPresented else {
            self.status = "Wait for the current screen transition to finish, then try again."
            self.refresh()
            return
        }
        self.nativeController = nativeController
        self.status = nil
        presenter.present(nativeController, animated: true, completion: nil)
        nativeController.presentationController?.delegate = self
        self.refresh()
    }

    private func closeNative(_ nativeController: UIViewController) {
        if self.nativeController === nativeController {
            self.nativeController = nil
        }
        nativeController.dismiss(animated: true, completion: nil)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard self.nativeController === presentationController.presentedViewController else {
            return
        }
        self.nativeController = nil
        self.status = "Selection cancelled."
        self.refresh()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.closeNative(controller)
        self.status = "Import cancelled."
        self.refresh()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        self.closeNative(controller)
        guard urls.count == 1, let url = urls.first else {
            self.status = "Choose one TTF or OTF file."
            self.refresh()
            return
        }
        self.busy = true
        self.status = "Importing font…"
        self.refresh()
        self.workQueue.async {
            let result = Result { try whitegramReadFont(url) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case let .success(fonts):
                    var history = whitegramFontHistory()
                    for font in fonts.reversed() {
                        history.removeAll { $0["name"] == font.name }
                        history.insert(whitegramFontHistoryValue(font), at: 0)
                    }
                    // Import does not silently change the active face; selection is explicit.
                    self.save(["fontHistory": history], success: "Imported \(fonts.count) font face(s). Tap a font below to use it.")
                case let .failure(error):
                    self.status = "Import failed: \(error.localizedDescription)"
                    self.refresh()
                }
            }
        }
    }

    func requestDelete(_ font: WhitegramFontRecord) {
        guard !self.busy, self.nativeController == nil else {
            return
        }
        let text = font.fileName == nil ? "Remove this font from Whitegram’s history?" : "Delete this imported file and every font face it contains?"
        let alert = UIAlertController(title: font.displayName, message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { [weak self] _ in
            self?.nativeController = nil
            self?.status = "Removal cancelled."
            self?.refresh()
        }))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive, handler: { [weak self] _ in
            guard let self = self else { return }
            self.nativeController = nil
            self.remove(font)
        }))
        self.presentNative(alert)
    }

    private func remove(_ font: WhitegramFontRecord) {
        guard let fileName = font.fileName else {
            self.finishRemoval(font, names: [font.name], warning: nil)
            return
        }
        self.busy = true
        self.status = "Removing font…"
        self.refresh()
        self.workQueue.async {
            let result = Result { try WhitegramFontRegistry.shared.removeFont(fileName: fileName) }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case let .success(removal):
                    self.finishRemoval(font, names: removal.names + [font.name], warning: removal.warning)
                case let .failure(error):
                    self.status = "Could not remove the font: \(error.localizedDescription)"
                    self.refresh()
                }
            }
        }
    }

    private func finishRemoval(_ font: WhitegramFontRecord, names: [String], warning: String?) {
        let history = whitegramFontHistory()
        let removedNames = Set(names + history.compactMap { value -> String? in
            if let fileName = font.fileName, value["fileName"] == fileName {
                return value["name"]
            }
            return nil
        })
        var changes: [String: Any] = ["fontHistory": history.filter { !removedNames.contains($0["name"] ?? "") }]
        if removedNames.contains(WhitegramPreferences.string("customFontName")) {
            changes["customFontEnabled"] = false
            changes["customFontName"] = ""
        }
        if WhitegramPreferences.update(changes) {
            self.status = warning ?? "Font removed."
        } else {
            self.status = font.fileName == nil ? "Could not update font history." : "The font file was removed, but its saved history could not be updated."
        }
        WhitegramFontRegistry.shared.invalidateCache()
        self.refresh()
    }
}

@available(iOS 13.0, *)
extension WhitegramFontsCoordinator: UIFontPickerViewControllerDelegate {
    func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) {
        self.closeNative(viewController)
        self.status = "Font selection cancelled."
        self.refresh()
    }

    func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
        self.closeNative(viewController)
        guard let descriptor = viewController.selectedFontDescriptor else {
            self.status = "No font was selected."
            self.refresh()
            return
        }
        let name = descriptor.postscriptName
        guard let font = WhitegramFontRegistry.shared.previewFont(named: name, size: 16.0) else {
            self.status = "\(name) is not available to Whitegram. Install it with its font provider or import a TTF/OTF file."
            self.refresh()
            return
        }
        let imported = WhitegramFontRegistry.shared.library().fonts.first { $0.name == font.fontName }
        self.select(imported ?? WhitegramFontRecord(name: font.fontName, displayName: font.fontName))
    }
}

public func whitegramFontsController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramFontsCoordinator(context: context)
    let signal = combineLatest(context.sharedContext.presentationData, coordinator.state.get())
        |> deliverOnMainQueue
        |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
            let data = ItemListPresentationData(presentationData)
            let controllerState = ItemListControllerState(presentationData: data, title: .text("Fonts"), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
            let listState = ItemListNodeState(presentationData: data, entries: whitegramFontEntries(state), style: .blocks, animateChanges: false)
            return (controllerState, (listState, coordinator))
        }
    let controller = ItemListController(context: context, state: signal)
    coordinator.controller = controller
    // ItemListController owns this closure and the state signal; the reverse link is weak.
    controller.didAppear = { [coordinator] _ in
        coordinator.refresh()
    }
    return controller
}
