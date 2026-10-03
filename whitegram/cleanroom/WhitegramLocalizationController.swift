import Foundation
import UIKit
import UniformTypeIdentifiers
import AccountContext
import Display
import ItemListUI
import PresentationDataUtils
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData

private final class WhitegramLocalizationExportDocument {
    let url: URL

    init(pack: WhitegramLocalizationPack) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("Whitegram-\(UUID().uuidString).wglocalizations")
        try Data(pack.serialized().utf8).write(to: url, options: .atomic)
    }

    func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    deinit {
        do { try remove() }
        catch { NSLog("Whitegram: localization export cleanup failed (%@)", String(describing: type(of: error))) }
    }
}

private struct WhitegramLocalizationEntry: ItemListNodeEntry {
    let stableId: String
    let order: Int
    let section: ItemListSectionId
    let title: String
    let subtitle: String?
    let checked: Bool?
    let action: Bool
    let enabled: Bool

    static func < (lhs: Self, rhs: Self) -> Bool { return lhs.order < rhs.order }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let coordinator = arguments as! WhitegramLocalizationCoordinator
        if let checked {
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: title,
                subtitle: subtitle, style: .left, checked: checked, enabled: enabled, zeroSeparatorInsets: false,
                sectionId: section, action: { coordinator.perform(stableId) })
        }
        if action {
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title,
                kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: section,
                style: .blocks, action: { if enabled { coordinator.perform(stableId) } })
        }
        return ItemListTextItem(presentationData: presentationData, text: .plain(title), sectionId: section, style: .blocks)
    }
}

private final class WhitegramLocalizationCoordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    let context: AccountContext
    let updates = ValuePromise<Int>(0, ignoreRepeated: true)
    weak var controller: ItemListController?
    private var revision = 0
    private var observers: [NSObjectProtocol] = []
    private var operation: UUID?
    private var modal: UIViewController?
    private var exportDocument: WhitegramLocalizationExportDocument?
    private var statusKey: String?
    private let queue = DispatchQueue(label: "Whitegram.Localization.Documents", qos: .userInitiated)

    init(context: AccountContext) {
        self.context = context
        super.init()
        for name in [WhitegramLocalizationStore.changedNotification, WhitegramPreferences.updatedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        let modal = self.modal
        DispatchQueue.main.async { modal?.dismiss(animated: false) }
    }

    private var language: String { return context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode } }
    private func text(_ key: String) -> String { return WhitegramLocalization.string(key, baseLanguage: language) }
    func refresh() { revision += 1; updates.set(revision) }
    func disappeared() { if modal == nil { operation = nil; cleanupExport() } }

    func entries(baseLanguage: String) -> [WhitegramLocalizationEntry] {
        let selected = WhitegramLocalization.selectedLanguage(baseLanguage: baseLanguage)
        let enabled = operation == nil && modal == nil
        var result: [WhitegramLocalizationEntry] = []
        for (code, title) in [("ru", "Русский"), ("uk", "Українська"), ("en", "English")] {
            result.append(WhitegramLocalizationEntry(stableId: "language." + code, order: result.count, section: 0,
                title: title, subtitle: WhitegramLocalization.string("language.\(code).subtitle", baseLanguage: baseLanguage),
                checked: code == selected, action: false, enabled: enabled))
        }
        for id in ["loc.export", "loc.import", "loc.remove"] {
            result.append(WhitegramLocalizationEntry(stableId: id, order: result.count, section: 1, title: text(id), subtitle: nil, checked: nil, action: true, enabled: enabled))
        }
        let summary: String
        do {
            if let pack = try WhitegramLocalizationStore.shared.activePack() {
                let count = pack.entries.keys.filter { WhitegramLocalizationStrings.values[$0] != nil }.count
                summary = [pack.name, pack.author, WhitegramLocalization.format("loc.activeFormat", [String(count), String(WhitegramLocalizationStrings.values.count)], baseLanguage: baseLanguage)].filter { !$0.isEmpty }.joined(separator: "\n")
            } else {
                summary = WhitegramLocalization.format("loc.noneSubtitle", [String(WhitegramLocalizationStrings.values.count)], baseLanguage: baseLanguage)
            }
        } catch { summary = text("loc.importFailed") }
        for (id, value) in [("summary", summary), ("hint", text("loc.hint"))] {
            result.append(WhitegramLocalizationEntry(stableId: id, order: result.count, section: 2, title: value, subtitle: nil, checked: nil, action: false, enabled: true))
        }
        if let statusKey {
            result.append(WhitegramLocalizationEntry(stableId: "status", order: result.count, section: 2, title: text(statusKey), subtitle: nil, checked: nil, action: false, enabled: true))
        }
        return result
    }

    func perform(_ id: String) {
        guard operation == nil, modal == nil else { return }
        if id.hasPrefix("language.") {
            if WhitegramLocalization.setLanguage(String(id.dropFirst(9))) { refresh() }
            return
        }
        switch id {
        case "loc.export": exportPack()
        case "loc.import":
            let picker: UIDocumentPickerViewController
            if #available(iOS 14.0, *) { picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false) }
            else { picker = UIDocumentPickerViewController(documentTypes: ["public.item"], in: .open) }
            picker.delegate = self
            picker.allowsMultipleSelection = false
            present(picker)
        case "loc.remove":
            run({ try WhitegramLocalizationStore.shared.remove() }, failure: "loc.importFailed") { [weak self] _ in self?.statusKey = "loc.removed" }
        default: break
        }
    }

    private func run<T>(_ work: @escaping () throws -> T, failure: String, completed: @escaping (T) -> Void) {
        let id = UUID()
        operation = id
        refresh()
        queue.async { [weak self] in
            let result = Result { try work() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.operation == id else { return }
                self.operation = nil
                switch result {
                case let .success(value): completed(value)
                case .failure: self.statusKey = failure
                }
                self.refresh()
            }
        }
    }

    private func exportPack() {
        let baseLanguage = language
        run({
            let pack = try WhitegramLocalization.exportPack(baseLanguage: baseLanguage)
            return try WhitegramLocalizationExportDocument(pack: pack)
        }, failure: "loc.exportFailed") { [weak self] document in
            guard let self else { return }
            self.exportDocument = document
            let picker: UIDocumentPickerViewController
            if #available(iOS 14.0, *) { picker = UIDocumentPickerViewController(forExporting: [document.url], asCopy: true) }
            else { picker = UIDocumentPickerViewController(url: document.url, in: .exportToService) }
            picker.delegate = self
            if !self.present(picker) { self.cleanupExport() }
        }
    }

    func importPack(from url: URL) {
        guard operation == nil else { return }
        run({
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            var coordinatedError: NSError?
            var decoded: Result<WhitegramLocalizationPack, Error>?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatedError) { coordinated in
                decoded = Result {
                    let data = try WhitegramLocalizationStore.readRegularFile(coordinated)
                    guard let source = String(data: data, encoding: .utf8), let pack = WhitegramLocalizationPack.parse(source) else {
                        throw WhitegramLocalizationStoreError.invalidFile
                    }
                    return pack
                }
            }
            if let coordinatedError { throw coordinatedError }
            guard let decoded else { throw WhitegramLocalizationStoreError.invalidFile }
            return try decoded.get()
        }, failure: "loc.importFailed") { [weak self] pack in self?.review(pack) }
    }

    private func review(_ pack: WhitegramLocalizationPack) {
        let count = pack.entries.keys.filter { WhitegramLocalizationStrings.values[$0] != nil }.count
        let summary = WhitegramLocalization.format("loc.previewFormat", [String(count), String(WhitegramLocalizationStrings.values.count)], baseLanguage: language)
        let alert = UIAlertController(title: pack.name, message: [pack.author, pack.languageCode, summary].filter { !$0.isEmpty }.joined(separator: "\n"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: text("common.cancel"), style: .cancel) { [weak self] _ in self?.modal = nil; self?.refresh() })
        alert.addAction(UIAlertAction(title: text("loc.apply"), style: .default) { [weak self] _ in
            guard let self else { return }
            self.modal = nil
            self.run({ try WhitegramLocalizationStore.shared.apply(pack) }, failure: "loc.importFailed") { [weak self] _ in self?.statusKey = "loc.applied" }
        })
        present(alert)
    }

    @discardableResult
    private func present(_ viewController: UIViewController) -> Bool {
        guard modal == nil, let controller, controller.viewIfLoaded?.window != nil, controller.presentedViewController == nil else { return false }
        modal = viewController
        controller.present(viewController, animated: true)
        viewController.presentationController?.delegate = self
        refresh()
        return true
    }

    private func cleanupExport() {
        guard let exportDocument else { return }
        do {
            try exportDocument.remove()
            self.exportDocument = nil
        } catch { statusKey = "loc.exportFailed" }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard modal === controller else { return }
        let wasExport = controller.documentPickerMode == .exportToService
        modal = nil
        controller.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            if wasExport { self.cleanupExport() }
            else if let url = urls.first { self.importPack(from: url) }
            self.refresh()
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard modal === controller else { return }
        modal = nil
        cleanupExport()
        refresh()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard modal === presentationController.presentedViewController else { return }
        modal = nil
        cleanupExport()
        refresh()
    }
}

public func whitegramLocalizationController(context: AccountContext, initialImportURL: URL? = nil) -> ViewController {
    let coordinator = WhitegramLocalizationCoordinator(context: context)
    let signal = combineLatest(context.sharedContext.presentationData, coordinator.updates.get())
    |> deliverOnMainQueue
    |> map { presentationData, _ -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let title = WhitegramLocalization.string("loc.title", baseLanguage: presentationData.strings.baseLanguageCode)
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title),
            leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false)
        let list = ItemListNodeState(presentationData: ItemListPresentationData(presentationData),
            entries: coordinator.entries(baseLanguage: presentationData.strings.baseLanguageCode), style: .blocks, animateChanges: false)
        return (state, (list, coordinator))
    }
    let controller = ItemListController(context: context, state: signal)
    coordinator.controller = controller
    var initialURL = initialImportURL
    controller.didAppear = { _ in
        if let url = initialURL { initialURL = nil; coordinator.importPack(from: url) }
    }
    controller.didDisappear = { _ in coordinator.disappeared() }
    return controller
}
