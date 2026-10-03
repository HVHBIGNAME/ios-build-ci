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

private struct WhitegramIconPackPreview: Equatable {
    let name: String
    let original: UIImage?
    let replacement: UIImage?
}

private struct WhitegramIconPacksState: Equatable {
    var packs: [WhitegramIconPackManifest] = []
    var activeId: String?
    var preview: WhitegramIconPackManifest?
    var images: [WhitegramIconPackPreview] = []
    var busy = false
    var error: String?
}

private struct WhitegramIconPackEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case text(String)
        case action(String, String, Bool)
        case pack(WhitegramIconPackManifest, Bool, Bool)
        case image(String, UIImage?)
    }
    let stableId: String
    let order: Int
    let section: ItemListSectionId
    let content: Content
    static func < (lhs: Self, rhs: Self) -> Bool { return lhs.order < rhs.order }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let coordinator = arguments as! WhitegramIconPacksCoordinator
        switch self.content {
        case let .text(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .action(id, title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: { if enabled { coordinator.perform(id) } })
        case let .pack(pack, selected, enabled):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, title: pack.name, subtitle: [pack.author, pack.version, "\(pack.iconCount)"].filter { !$0.isEmpty }.joined(separator: " · "), style: .right, checked: selected, enabled: enabled, zeroSeparatorInsets: false, sectionId: self.section, action: {
                coordinator.activate(pack.id)
            }, deleteAction: {
                coordinator.requestDelete(pack)
            })
        case let .image(title, image):
            return ItemListCheckboxItem(presentationData: presentationData, systemStyle: .glass, icon: image, iconSize: CGSize(width: 32, height: 32), title: title, style: .right, checked: false, enabled: false, zeroSeparatorInsets: false, sectionId: self.section, action: {})
        }
    }
}

private final class WhitegramIconPacksCoordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    let context: AccountContext
    let state = ValuePromise(WhitegramIconPacksState(), ignoreRepeated: true)
    weak var controller: ItemListController?
    private let queue = DispatchQueue(label: "Whitegram.IconPackImport", qos: .userInitiated)
    private var nativeController: UIViewController?
    private var staged: WhitegramIconPackManager.StagedPack?
    private var previews: [WhitegramIconPackPreview] = []
    private var busy = false
    private var error: String?
    private var observer: NSObjectProtocol?

    init(context: AccountContext) {
        self.context = context
        super.init()
        WhitegramIconPackManager.shared.setUpAtLaunch()
        self.observer = NotificationCenter.default.addObserver(forName: WhitegramIconPackManager.changedNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
        self.refresh()
    }

    deinit {
        if let observer = self.observer { NotificationCenter.default.removeObserver(observer) }
        if let native = self.nativeController { DispatchQueue.main.async { native.dismiss(animated: false, completion: nil) } }
    }

    func text(_ ru: String, _ en: String) -> String {
        return self.context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode.lowercased().hasPrefix("ru") } ? ru : en
    }

    private func localized(_ key: String) -> String {
        return WhitegramLocalization.string(key, baseLanguage: self.context.sharedContext.currentPresentationData.with { $0.strings.baseLanguageCode })
    }

    func refresh() {
        var packs: [WhitegramIconPackManifest] = []
        do { packs = try WhitegramIconPackManager.shared.installedPacks() }
        catch { self.error = error.localizedDescription }
        self.state.set(WhitegramIconPacksState(packs: packs, activeId: WhitegramIconPackManager.shared.activeId, preview: self.staged?.manifest, images: self.previews, busy: self.busy || self.nativeController != nil, error: self.error ?? WhitegramIconPackManager.shared.loadError))
    }

    private func present(_ native: UIViewController) {
        guard var presenter = self.controller?.viewIfLoaded?.window?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !presenter.isBeingPresented, !presenter.isBeingDismissed else { return }
        self.nativeController = native
        presenter.present(native, animated: true, completion: nil)
        native.presentationController?.delegate = self
        self.refresh()
    }

    func perform(_ action: String) {
        guard !self.busy, self.nativeController == nil else { return }
        switch action {
        case "import":
            let picker: UIDocumentPickerViewController
            if #available(iOS 14.0, *) {
                picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .zip], asCopy: true)
            } else {
                picker = UIDocumentPickerViewController(documentTypes: ["public.data", "public.zip-archive"], in: .import)
            }
            picker.allowsMultipleSelection = false
            picker.delegate = self
            picker.modalPresentationStyle = .formSheet
            self.present(picker)
        case "install":
            guard let staged = self.staged else { return }
            let existing: [WhitegramIconPackManifest]
            do { existing = try WhitegramIconPackManager.shared.installedPacks() }
            catch { self.error = error.localizedDescription; self.refresh(); return }
            if existing.contains(where: { $0.id == staged.manifest.id }) {
                self.confirm(title: self.text("Заменить набор?", "Replace Icon Pack?"), message: staged.manifest.name, actionTitle: self.text("Заменить", "Replace")) { $0.installPreview() }
            } else {
                self.installPreview()
            }
        case "cancel":
            self.staged = nil
            self.previews = []
            self.error = nil
            self.refresh()
        case "reset": self.activate(nil)
        case "builder": whitegramOpenIconPackBuilder(context: self.context)
        default: break
        }
    }

    func activate(_ id: String?) {
        guard !self.busy, self.nativeController == nil else { return }
        do { try WhitegramIconPackManager.shared.activate(id); self.error = nil }
        catch { self.error = error.localizedDescription }
        self.refresh()
    }

    private func installPreview() {
        guard let staged = self.staged else { return }
        do {
            try WhitegramIconPackManager.shared.install(staged)
            self.staged = nil
            self.previews = []
            self.error = nil
        } catch { self.error = error.localizedDescription }
        self.refresh()
    }

    func requestDelete(_ pack: WhitegramIconPackManifest) {
        guard !self.busy, self.nativeController == nil else { return }
        self.confirm(title: self.localized("icons.packs.deleteConfirmTitle"), message: pack.name, actionTitle: self.localized("common.delete")) { owner in
            do { try WhitegramIconPackManager.shared.delete(pack.id); owner.error = nil }
            catch { owner.error = error.localizedDescription }
            owner.refresh()
        }
    }

    private func confirm(title: String, message: String, actionTitle: String, action: @escaping (WhitegramIconPacksCoordinator) -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.localized("common.cancel"), style: .cancel, handler: { [weak self] _ in self?.nativeController = nil; self?.refresh() }))
        alert.addAction(UIAlertAction(title: actionTitle, style: .destructive, handler: { [weak self] _ in
            guard let self else { return }
            self.nativeController = nil
            action(self)
        }))
        self.present(alert)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        self.nativeController = nil
        controller.dismiss(animated: true, completion: nil)
        self.refresh()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        self.nativeController = nil
        self.refresh()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        self.nativeController = nil
        controller.dismiss(animated: true, completion: nil)
        guard urls.count == 1, let url = urls.first else { return }
        self.busy = true
        self.error = nil
        self.refresh()
        self.queue.async {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var result: Result<(WhitegramIconPackManager.StagedPack, [WhitegramIconPackPreview]), Error>?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { coordinated in
                result = Result {
                    let staged = try WhitegramIconPackManager.shared.inspectArchive(at: coordinated)
                    let images = try WhitegramIconPackManager.shared.preview(staged).map { WhitegramIconPackPreview(name: $0.0, original: $0.1, replacement: $0.2) }
                    return (staged, images)
                }
            }
            let outcome = coordinationError.map { Result<(WhitegramIconPackManager.StagedPack, [WhitegramIconPackPreview]), Error>.failure($0) } ?? result ?? .failure(WhitegramIconPackError("The file provider did not supply the archive."))
            DispatchQueue.main.async {
                self.busy = false
                switch outcome {
                case let .success((staged, images)): self.staged = staged; self.previews = images
                case let .failure(error): self.error = error.localizedDescription
                }
                self.refresh()
            }
        }
    }
}

public func whitegramOpenIconPackBuilder(context: AccountContext) {
    context.sharedContext.applicationBindings.openUrl("https://whitegram.click")
}

public func whitegramIconPacksController(context: AccountContext) -> ViewController {
    let coordinator = WhitegramIconPacksCoordinator(context: context)
    let signal = combineLatest(context.sharedContext.presentationData, coordinator.state.get())
    |> deliverOnMainQueue
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let russian = presentationData.strings.baseLanguageCode.lowercased().hasPrefix("ru")
        func text(_ ru: String, _ en: String) -> String { return russian ? ru : en }
        func localized(_ key: String) -> String { return WhitegramLocalization.string(key, baseLanguage: presentationData.strings.baseLanguageCode) }
        var entries: [WhitegramIconPackEntry] = []
        func add(_ id: String, _ section: Int32, _ content: WhitegramIconPackEntry.Content) {
            entries.append(WhitegramIconPackEntry(stableId: id, order: entries.count, section: section, content: content))
        }
        if let error = state.error { add("error", 0, .text(error)) }
        add("import", 1, .action("import", text("Импорт .wgicons / .zip", "Import .wgicons / .zip"), !state.busy))
        add("builder", 1, .action("builder", localized("s.createIconPack"), !state.busy))
        add("reset", 1, .action("reset", text("Стандартные иконки", "Use Bundled Icons"), !state.busy))
        if let preview = state.preview {
            add("preview", 2, .text([preview.name, preview.author, preview.packDescription, "\(preview.iconCount) " + text("иконок и анимаций", "icons and animations")].filter { !$0.isEmpty }.joined(separator: "\n")))
            if !preview.monochrome { add("colorWarning", 2, .text(localized("icons.install.colorWarning"))) }
            if state.images.isEmpty { add("noPreview", 2, .text(localized("icons.install.noPreview"))) }
            else { add("comparison", 2, .text(localized("icons.install.comparison"))) }
            for image in state.images {
                add("old:" + image.name, 2, .image(text("Было: ", "Original: ") + image.name, image.original))
                add("new:" + image.name, 2, .image(text("Станет: ", "Replacement: ") + image.name, image.replacement))
            }
            add("install", 2, .action("install", localized("icons.install.action"), !state.busy))
            add("cancel", 2, .action("cancel", localized("common.cancel"), !state.busy))
        }
        for pack in state.packs { add("pack:" + pack.id, 3, .pack(pack, pack.id == state.activeId, !state.busy)) }
        if state.packs.isEmpty { add("empty", 3, .text(localized("icons.packs.emptySubtitle"))) }
        add("packInfo", 4, .text(localized("icons.info")))
        add("info", 4, .text(text("Нажмите на набор, чтобы применить его. Смахните влево, чтобы удалить. Наборы заменяют ресурсы интерфейса; иконка приложения выбирается отдельно. Часть уже открытых экранов нужно открыть заново.", "Tap a pack to apply it; swipe left to delete. Packs replace interface resources. Choose the home-screen app icon separately. Some existing screens need to be reopened.")))
        let data = ItemListPresentationData(presentationData)
        return (ItemListControllerState(presentationData: data, title: .text(localized("icons.packs.title")), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back), animateChanges: false),
                (ItemListNodeState(presentationData: data, entries: entries, style: .blocks, animateChanges: false), coordinator))
    }
    let controller = ItemListController(context: context, state: signal)
    coordinator.controller = controller
    controller.didAppear = { [coordinator] _ in coordinator.refresh() }
    return controller
}
